import AVFoundation
import Foundation

/// Playback state belongs to queue. Graph lifecycle/latency getters belong to control.
/// Neither queue is an audio render callback; framework rendering remains allocation-free here.
public final class AudioRenderer {
  private let queue = DispatchQueue(label: "dev.silentdisco.audio.render", qos: .userInitiated)
  private let control: AudioControlQueue
  private let mailbox = AudioPacketMailbox()
  private let wake: DispatchSourceUserDataAdd
  private var graph: PlaybackGraph? // scheduler lease; relinquished before any graph mutation
  private var controlGraph: PlaybackGraph? // control queue only
  private var monitor: DispatchSourceTimer? // control queue only
  private var configurationObserver: NSObjectProtocol? // control queue only
  private var graphEpoch: UInt64 = 0
  private var playbackEpoch: UInt64 = 0
  private var latency = LatencySnapshotStore()
  private var codec: AudioCodec?
  private var jitter = AudioJitterBuffer()
  private var timer: DispatchSourceTimer?
  private var generation: UInt64 = 0
  private var offset = 0.0
  private var sourceAnchor: Double?
  private var sourceSampleBase: Int64 = 0
  private var anchor = 0.0
  private var nextPresentation = 0.0
  private var fadeUntil: Double?
  private var endSequence: UInt64?
  private var scheduled = 0
  private var concealed = 0
  private var losses = 0
  private var consecutive = 0
  private var underruns = 0
  private var rebuffer = 0
  private var errorMs: Double?
  private var playing = false
  private var active = false
  private var lastStats = 0.0
  private var awaitingAfterLoss = false
  private var rate: Float = 1
  private var offsetAdjustment = 0.0
  private var initialLatency: PlaybackLatency?
  private var measurements = RenderMeasurements()
  private var passDiagnostics = RendererPassDiagnostics()
  private var observations = TimingObservationWindow()
  private var timingController = PlaybackTimingController()
  private var latestTiming: PlaybackTiming?
  private var latestPoint: OutputClockPoint?
  private var packetEvidence = [String: Any]()
  private var calls = AudioCallMeasurements()
  private var incidents = PacketIncidentEvidence()
  private var recoveries = RecoveryTimeline()
  private var lastAdmission: Double?
  private var recoveryCounts = [String: Int]()
  private var maxAdmissionDelay = 0.0
  private let probeEnabled = ProcessInfo.processInfo.environment["SD_AUDIO_LATENCY_PROBE"] == "1"
    || UserDefaults.standard.bool(forKey: "SDAudioLatencyProbe")
  public var onDiagnostic: ((UInt64, Double, String, [String: Any]) -> Void)?
  public var onStats: (([String: Any]) -> Void)?
  public var onEvent: ((String) -> Void)?
  public var onError: ((String) -> Void)?

  public convenience init() { self.init(control: AudioControlQueue()) }
  init(control: AudioControlQueue) {
    self.control = control
    wake = DispatchSource.makeUserDataAddSource(queue: queue)
    wake.setEventHandler { [weak self] in self?.tick(timerTick: false) }
    wake.resume()
  }
  private func measured<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
    let start = AudioWire.now()
    defer { passDiagnostics.stage(stage, seconds: AudioWire.now() - start) }
    return try AudioTrace.interval(stage, work)
  }
  public func start(generation: UInt64, offset: Double, sourceAnchor: Double? = nil) {
    queue.async {
      let sameRun = self.generation == generation
      let pending = self.mailbox.suspend()
      if self.active {
        self.captureReset("Graph restarted", category: "graphRecovery")
        self.captureAbandonedPCM()
      }
      self.timer?.cancel(); self.timer = nil
      self.graph = nil // quiescence: no subsequent scheduling touches the retired graph
      self.active = true; self.playing = false; self.scheduled = 0
      self.fadeUntil = nil; self.awaitingAfterLoss = false; self.consecutive = 0
      self.endSequence = nil; self.rate = 1; self.latestTiming = nil; self.latestPoint = nil
      self.generation = generation; self.offset = offset
      if !sameRun {
        self.jitter = AudioJitterBuffer()
        self.measurements = RenderMeasurements(); self.passDiagnostics = RendererPassDiagnostics()
        self.observations = TimingObservationWindow(); self.timingController = PlaybackTimingController()
        self.concealed = 0; self.losses = 0; self.underruns = 0; self.rebuffer = 0
        self.offsetAdjustment = 0; self.initialLatency = nil; self.packetEvidence = [:]
        self.recoveryCounts = [:]; self.maxAdmissionDelay = 0
        self.calls = AudioCallMeasurements(); self.incidents = PacketIncidentEvidence()
        self.recoveries = RecoveryTimeline(); self.lastAdmission = nil
        self.sourceAnchor = sourceAnchor
      } else {
        self.jitter.rejoin(); self.rebuffer += 1
        self.admitPackets(pending)
      }
      self.mailbox.begin(generation, stored: self.jitter.packets.count, resetCounters: !sameRun)
      do { self.codec = try AudioCodec() }
      catch {
        self.stopInternal(preservePackets: false)
        self.onError?(error.localizedDescription); return
      }
      self.beginGraph()
    }
  }
  /// Scheduler already relinquished the old lease. Lifecycle and reads execute serially.
  private func beginGraph() {
    graphEpoch &+= 1
    let epoch = graphEpoch
    latency.begin(epoch)
    control.queue.async {
      let retirement = self.retireControlGraph()
      do {
        let g = try PlaybackGraph(epoch: epoch)
        self.controlGraph = g
        let snapshot = g.latency(site: "startup")
        self.configurationObserver = NotificationCenter.default.addObserver(
          forName: .AVAudioEngineConfigurationChange, object: g.engine, queue: nil
        ) { [weak self] _ in
          self?.queue.async { [weak self] in
            guard let self = self, self.active, self.graphEpoch == epoch else { return }
            self.captureReset("Audio engine configuration changed", category: "graphRecovery")
            self.captureAbandonedPCM()
            self.timer?.cancel(); self.timer = nil; self.graph = nil
            self.playing = false; self.scheduled = 0; self.consecutive = 0; self.rate = 1
            self.fadeUntil = nil; self.awaitingAfterLoss = false; self.latestTiming = nil
            self.jitter.rejoin(); self.codec?.resetDecoder(); self.rebuffer += 1
            self.beginGraph()
          }
        }
        let monitor = DispatchSource.makeTimerSource(queue: self.control.queue)
        monitor.schedule(deadline: .now() + (self.probeEnabled ? 0.005 : 1),
          repeating: self.probeEnabled ? .milliseconds(5) : .seconds(1))
        var probeTick = 0
        monitor.setEventHandler { [weak self, weak g] in
          guard let self = self, let g = g, self.controlGraph === g else { return }
          probeTick += 1
          let packetProbe = self.probeEnabled && probeTick % 4 == 0
          self.control.refresh(read: {
            // Lifecycle work may have retired this graph while the refresh was queued.
            guard self.controlGraph === g else { return snapshot }
            let value = g.latency(site: self.probeEnabled ? "probeTick" : "periodic")
            return packetProbe ? g.latency(site: "probePacket") : value
          }, deliver: { [weak self] value in
            self?.queue.async { [weak self] in self?.acceptLatency(value) }
          })
        }
        self.monitor = monitor; monitor.resume()
        self.queue.async {
          guard self.active, self.graphEpoch == epoch else { return }
          self.graph = g
          self.recoveries.update(retirement)
          self.acceptLatency(snapshot)
          self.measurements.resetBoundary()
          let timer = DispatchSource.makeTimerSource(queue: self.queue)
          timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
          timer.setEventHandler { [weak self] in self?.tick(timerTick: true) }
          self.timer = timer; timer.resume()
          self.wake.add(data: 1)
        }
      } catch {
        self.queue.async {
          guard self.graphEpoch == epoch else { return }
          self.active = false
          self.onError?(error.localizedDescription)
        }
      }
    }
  }
  @discardableResult private func retireControlGraph() -> [String: Any] {
    monitor?.cancel(); monitor = nil
    if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
    configurationObserver = nil
    guard let old = controlGraph else { return [:] }
    let entered = AudioWire.now()
    AudioTrace.interval("graphStop") { old.stop() }
    let returned = AudioWire.now()
    controlGraph = nil
    return ["stopEnteredAt": entered, "stopReturnedAt": returned, "retiredGraphEpoch": String(old.epoch)]
  }
  private func acceptLatency(_ value: LatencySnapshot) {
    guard active, latency.accept(value) else { return }
    if initialLatency == nil { initialLatency = value.value }
    wake.add(data: 1)
  }
  public func finish(after sequence: UInt64?) {
    queue.async {
      self.endSequence = sequence
      if sequence == nil { self.stopInternal(preservePackets: false); self.emit() }
      else { self.wake.add(data: 1) }
    }
  }
  public func clock(_ value: Double) {
    queue.async {
      guard value.isFinite else { return }
      self.offsetAdjustment = value - self.offset; self.offset = value
    }
  }
  public func receive(_ packet: AudioPacket, callbackAt: Double = AudioWire.now()) {
    mailbox.offer(packet, at: callbackAt)
    wake.add(data: 1)
  }
  public func stop(preservePackets: Bool = false, completion: (() -> Void)? = nil) {
    queue.async {
      self.stopInternal(preservePackets: preservePackets, completion: completion)
      self.emit()
    }
  }
  private func stopInternal(preservePackets: Bool, completion: (() -> Void)? = nil) {
    if active { captureReset("Renderer stopped or restarted", category: "stopped") }
    if preservePackets && active {
      captureReset("Playback suspended for session recovery", category: "sessionRecovery")
      captureAbandonedPCM()
    }
    let stoppedGeneration = generation
    let pending = mailbox.suspend()
    if preservePackets { admitPackets(pending) }
    timer?.cancel(); timer = nil
    graph = nil; active = false; playing = false
    graphEpoch &+= 1 // reject late startup/refresh/notification deliveries
    fadeUntil = nil; awaitingAfterLoss = false; latestTiming = nil; latestPoint = nil; errorMs = nil
    if preservePackets { jitter.rejoin() } else { jitter.reset() }
    mailbox.begin(0, stored: jitter.packets.count, resetCounters: false)
    control.queue.async {
      let retirement = self.retireControlGraph()
      self.queue.async {
        if self.generation == stoppedGeneration { self.recoveries.update(retirement) }
        if self.generation == stoppedGeneration { self.diagnostic("graphTeardownCompleted", fields: [:]) }
        completion?()
      }
    }
  }
  private func timestampCall<T>(_ name: String, _ work: () -> T) -> T {
    let start = AudioWire.now()
    let value = AudioTrace.interval(name, work)
    calls.record(name, site: "scheduler", start: start, end: AudioWire.now(),
      graph: graphEpoch, playback: playbackEpoch)
    return value
  }
  /// Immutable counters captured on the scheduler before packet cleanup or graph teardown.
  public func finalSnapshot(_ completion: @escaping ([String: Any]) -> Void) {
    queue.async {
      self.drainPackets()
      completion(self.statistics())
      self.stopInternal(preservePackets: false)
    }
  }
  private func readTiming(_ g: PlaybackGraph, latency: PlaybackLatency) -> PlaybackTiming {
    let node = timestampCall("player.lastRenderTime") { g.player.lastRenderTime }
    let position = node.flatMap { stamp in
      timestampCall("playerTime(forNodeTime:)") { g.player.playerTime(forNodeTime: stamp) }
    }
    return PlaybackTiming(
      nodeHost: node.flatMap { $0.isHostTimeValid ? AVAudioTime.seconds(forHostTime: $0.hostTime) : nil },
      sampleTime: position.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil },
      sampleRate: position?.sampleRate ?? 0, offset: offset,
      presentationAnchor: sourceAnchor ?? 0, latency: latency,
      nodeSampleTime: node.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil },
      nodeSampleRate: node?.sampleRate, sourceSampleBase: sourceSampleBase)
  }
  private func readOutput(_ g: PlaybackGraph, timing: PlaybackTiming) -> OutputClockPoint? {
    guard let output = timestampCall("output.lastRenderTime", { g.output.lastRenderTime }), output.isHostTimeValid, output.isSampleTimeValid else { return nil }
    let stamp = output.audioTimeStamp
    let scalar = stamp.mFlags.contains(.rateScalarValid) ? stamp.mRateScalar : nil
    return OutputClockPoint(epoch: playbackEpoch, captured: AudioWire.now(),
      host: AVAudioTime.seconds(forHostTime: output.hostTime), samples: output.sampleTime,
      sampleRate: output.sampleRate, playerSamples: timing.sampleTime, rateScalar: scalar)
  }
  private func headroom(at now: Double) -> Double? {
    SchedulingPolicy.headroom(scheduled: scheduled, timing: latestTiming, now: now,
      start: anchor, rate: Double(rate), outputSlope: timingController.slope)
  }
  private func drainPackets() {
    for rejection in mailbox.drainRejections() { incidents.record(rejection) }
    admitPackets(mailbox.drain())
  }
  private func admitPackets(_ entries: [AudioPacketMailbox.Entry]) {
    for entry in entries {
      let now = AudioWire.now()
      measurements.packetQueue(now - entry.callbackAt)
      maxAdmissionDelay = max(maxAdmissionDelay, now - entry.callbackAt)
      let snapshot = latency.snapshot
      let margin: Double?
      if playing, let next = jitter.expected, entry.packet.sequence >= next, let available = headroom(at: now) {
        margin = available + Double(entry.packet.sequence - next) * 0.020 / max(0.01, timingController.slope)
      } else {
        margin = snapshot.map { entry.packet.presentation - offset - $0.value.pipeline - now }
      }
      packetEvidence = ["callbackMonotonicSeconds": entry.callbackAt,
        "admittedMonotonicSeconds": now, "sequence": String(entry.packet.sequence),
        "deadlineMarginMs": margin.map { $0 * 1000 } as Any? ?? NSNull()]
      let lateBefore = jitter.lateAfterConcealment
      let countBefore = jitter.packets.count
      jitter.insert(entry.packet, hostNow: now + offset,
        outputLead: snapshot?.value.pipeline ?? 0,
        enforcePresentationDeadline: !playing && snapshot != nil)
      packetEvidence["expectedSequence"] = jitter.expected.map(String.init) as Any? ?? NSNull()
      packetEvidence["contiguousEncodedMs"] = jitter.contiguousPackets * 20
      packetEvidence["headroomMs"] = headroom(at: now).map { $0 * 1000 } as Any? ?? NSNull()
      packetEvidence["decision"] = jitter.packets.count > countBefore ? "admitted"
        : jitter.lateAfterConcealment > lateBefore ? "lateAfterPLC" : "rejectedLateDuplicateOrCapacity"
      incidents.record(packetEvidence)
      if lastAdmission.map({ entry.callbackAt - $0 > 0.100 }) == true {
        freezeIncident("deliveryGap", at: now)
      }
      lastAdmission = entry.callbackAt
    }
    mailbox.account(stored: jitter.packets.count)
  }
  private func freezeIncident(_ reason: String, at: Double) {
    diagnostic("packetIncident", fields: ["incident": incidents.freeze(reason, at: at)])
  }
  private func diagnostic(_ kind: String, fields: [String: Any]) {
    var fields = fields
    fields["diagnosticKind"] = kind; fields["clockOffsetMs"] = offset * 1000
    let now = AudioWire.now()
    onDiagnostic?(generation, now, ISO8601DateFormatter().string(from: Date()), fields)
  }
  private func evidence(at now: Double) -> [String: Any] {
    var fields = measurements.json
    fields["timestampCalls"] = calls.json
    fields["recoveryTimeline"] = recoveries.json
    fields["packetIncidents"] = incidents.json
    fields["traceEnabled"] = AudioTrace.enabled
    fields["timingRecoveryPolicy"] = "observeWithoutRejoin"
    fields["passDiagnostics"] = passDiagnostics.json(at: now)
    fields["latencySnapshot"] = latency.snapshot?.json(at: now) as Any? ?? NSNull()
    fields["latencyProbeEnabled"] = probeEnabled
    fields["timingSummary"] = timingController.summary
    fields["graphEpoch"] = String(graphEpoch); fields["playbackEpoch"] = String(playbackEpoch)
    fields["sourcePresentationAnchorMacSeconds"] = sourceAnchor as Any? ?? NSNull()
    fields["sourceSampleBase"] = sourceSampleBase
    fields["scheduledSamples"] = scheduled
    fields["playbackRate"] = rate
    fields["compressedBufferMs"] = jitter.packets.count * 20
    fields["contiguousEncodedMs"] = jitter.contiguousPackets * 20
    fields["packetAdmission"] = packetEvidence
    fields["maxAdmissionDelayMs"] = maxAdmissionDelay * 1000
    fields["mailbox"] = mailbox.json
    fields["maximumReorderDepth"] = jitter.maximumReorderDepth
    fields["lateAfterPLC"] = jitter.lateAfterConcealment
    fields["recoveryCounts"] = recoveryCounts
    fields["clockOffsetAdjustmentMs"] = offsetAdjustment * 1000
    if let timing = latestTiming { fields.merge(timing.json(scheduled: scheduled, rate: Double(rate))) { _, new in new } }
    let available = playing ? headroom(at: now) : nil
    fields["estimatedPlayableAudioMs"] = available.map { max(0, $0) * 1000 } as Any? ?? NSNull()
    fields["nextConsumptionDeadlineMs"] = available.map { $0 * 1000 } as Any? ?? NSNull()
    fields["nextRenderingDeadlineMs"] = playing ? latency.snapshot.map {
      (nextPresentation - offset - $0.value.pipeline - now) * 1000
    } as Any? ?? NSNull() : NSNull()
    if let initial = initialLatency, let current = latency.snapshot?.value {
      fields["outputLatencyChangeMs"] = current.hardware.isFinite && initial.hardware.isFinite
        ? (current.hardware - initial.hardware) * 1000 as Any : NSNull()
      fields["pipelineLatencyChangeMs"] = (current.pipeline - initial.pipeline) * 1000
    }
    return fields
  }
  private func captureReset(_ reason: String, category: String) {
    if category != "stopped" { recoveryCounts[category, default: 0] += 1 }
    let now = AudioWire.now()
    if category != "stopped" {
      recoveries.begin(reason: reason, category: category, at: now, fields: [
        "phaseErrorMs": errorMs as Any? ?? NSNull(), "confidence": timingController.state.rawValue,
        "latencyAgeMs": latency.snapshot.map { $0.age(at: now) * 1000 } as Any? ?? NSNull(),
        "availablePCMms": headroom(at: now).map { $0 * 1000 } as Any? ?? NSNull(),
        "committedBoundary": jitter.expected.map(String.init) as Any? ?? NSNull(),
        "preservedFirstSequence": jitter.packets.keys.min().map(String.init) as Any? ?? NSNull(),
        "preservedLastSequence": jitter.packets.keys.max().map(String.init) as Any? ?? NSNull()])
      freezeIncident("recovery", at: now)
    }
    var fields = evidence(at: now)
    fields["reason"] = reason; fields["recoveryCategory"] = category
    fields["timingObservations"] = observations.observations
    diagnostic(category == "stopped" ? "rendererStopped" : "playbackReset", fields: fields)
  }
  private func resync(_ reason: String, category: String) {
    guard fadeUntil == nil else { return }
    captureReset(reason, category: category)
    recoveries.update(["fadeStartedAt": AudioWire.now()])
    fadeUntil = AudioWire.now() + 0.020
    onEvent?(reason)
  }
  private func captureAbandonedPCM() {
    recoveries.update(["abandonedPCMFrames": latestTiming?.actual.map {
      Int(max(0, Double(scheduled) - $0 * 48000))
    } as Any? ?? NSNull()])
  }
  private func resetPlayback(_ g: PlaybackGraph) {
    let stopAt = AudioWire.now()
    recoveries.update(["fadeEndedAt": stopAt, "stopEnteredAt": stopAt,
      "abandonedPCMFrames": latestTiming?.actual.map { Int(max(0, Double(scheduled) - $0 * 48000)) } as Any? ?? NSNull()])
    measured("playbackStop") { g.player.stop() }
    recoveries.update(["stopReturnedAt": AudioWire.now()])
    g.mixer.outputVolume = 1
    playing = false; scheduled = 0; consecutive = 0; awaitingAfterLoss = false; fadeUntil = nil
    jitter.rejoin() // retain future data, including packets that arrived during PLC/fade
    codec?.resetDecoder()
    setRate(1, graph: g)
    latestTiming = nil; latestPoint = nil; errorMs = nil
    measurements.resetBoundary(); rebuffer += 1
    wake.add(data: 1)
  }
  private func setRate(_ value: Float, graph: PlaybackGraph) {
    guard abs(value - rate) >= 0.00001 else { return }
    measured("rateChange") { graph.speed.rate = value }
    rate = value
  }
  private func tick(timerTick: Bool) {
    guard active else { return }
    let began = AudioWire.now()
    if timerTick { measurements.tick(began) }
    passDiagnostics.begin(at: began)
    defer {
      mailbox.account(stored: jitter.packets.count)
      let reportAt = AudioWire.now()
      if reportAt - lastStats >= 1 {
        lastStats = reportAt
        measured("statistics") { emit() }
      }
      let end = AudioWire.now()
      measurements.pass(end - began)
      if let pass = passDiagnostics.finish(at: end) { diagnostic("slowRendererPass", fields: ["pass": pass]) }
    }
    drainPackets()
    guard let g = graph, let snapshot = latency.snapshot else { return }
    if let deadline = fadeUntil {
      let now = AudioWire.now()
      g.mixer.outputVolume = Float(max(0, min(1, (deadline - now) / 0.020)))
      if now >= deadline { resetPlayback(g) }
      return
    }
    if !playing {
      let beforeSelection = jitter.packets.keys.sorted()
      jitter.discard(before: AudioWire.now() + offset + snapshot.value.pipeline + 0.030)
      guard let first = jitter.first,
        jitter.contiguousPackets >= 3 || (endSequence != nil && first.sequence <= endSequence!) else { return }
      recoveries.update(["restartSequence": String(first.sequence), "sourceSampleBase": String(first.sample),
        "skippedEncodedSequences": beforeSelection.filter { $0 < first.sequence }.map(String.init)])
      jitter.begin(at: first.sequence)
      if sourceAnchor == nil { sourceAnchor = first.presentation - Double(first.sequence) * 0.020 }
      sourceSampleBase = Int64(first.sample)
      nextPresentation = first.presentation
      anchor = first.presentation - offset - snapshot.value.pipeline
      scheduled = 0; consecutive = 0; playing = true
      playbackEpoch &+= 1
      timingController.restart(epoch: playbackEpoch)
      observations = TimingObservationWindow()
    }
    // Once the final frame is queued, let the session's drain timer stop the graph.
    if let end = endSequence, let next = jitter.expected, next > end { return }
    let timing = measured("timestampRead") { readTiming(g, latency: snapshot.value) }
    let point = measured("observationRead") { readOutput(g, timing: timing) }
    latestTiming = timing; latestPoint = point
    let now = AudioWire.now()
    let phaseError = now >= anchor + 0.100 && timing.actual.map({ $0 >= 0 }) == true ? timing.error : nil
    errorMs = phaseError.map { $0 * 1000 }
    let decision = timingController.observe(point, error: phaseError,
      latencyFresh: snapshot.age(at: now) <= 3, at: now, timingActive: now >= anchor + 0.100, clockOffset: offset)
    if observations.due(at: now) {
      var fields = timing.json(scheduled: scheduled, rate: Double(rate))
      fields["output"] = point?.json as Any? ?? NSNull()
      fields["clockOffsetMs"] = offset * 1000
      fields["playbackRate"] = rate; fields["scheduledSamples"] = scheduled
      fields["sourcePresentationAnchorMacSeconds"] = sourceAnchor as Any? ?? NSNull()
      observations.append(at: now, fields: fields)
    }
    if let event = decision.episodeEvent {
      diagnostic(event, fields: ["timingSummary": timingController.summary,
        "clockOffsetAdjustmentMs": offsetAdjustment * 1000])
    }
    if let sample = timing.sampleTime, sample > 0, timing.valid,
      let record = recoveries.progressed(at: now) {
      diagnostic("recoveryCompleted", fields: ["recovery": record])
    }
    if decision.stateChanged {
      diagnostic("timingStateChanged", fields: ["timingSummary": timingController.summary,
        "latencyAgeMs": snapshot.age(at: now) * 1000,
        "headroomMs": headroom(at: now).map { $0 * 1000 } as Any? ?? NSNull()])
    }
    setRate(decision.correctionAllowed ? PlaybackPolicy.rate(error: phaseError ?? 0) : 1, graph: g)
    if awaitingAfterLoss {
      if let remaining = headroom(at: AudioWire.now()), remaining <= 0 {
        captureReset("Rebuffering after six missing frames", category: "missingAudio")
        onEvent?("Rebuffering after missing audio")
        resetPlayback(g)
      }
      return
    }
    if scheduled > 0, let remaining = headroom(at: AudioWire.now()), remaining < -0.020 {
      underruns += 1
      resync("Render queue exhausted", category: "schedulerStarvation"); return
    }
    var count = 0
    while count < SchedulingPolicy.maxFramesPerPass {
      let freshNow = AudioWire.now()
      if count > 0 && freshNow - began >= SchedulingPolicy.passBudget { break }
      let atEnd = endSequence != nil && jitter.expected.map { $0 > endSequence! } == true
      let action = scheduled == 0 && jitter.nextPacket != nil && !atEnd
        ? SchedulingPolicy.Action.packet
        : SchedulingPolicy.action(headroom: headroom(at: freshNow),
          packetAvailable: jitter.nextPacket != nil, consecutiveLosses: consecutive, atEnd: atEnd)
      guard action == .packet || action == .conceal, let sequence = jitter.expected else { break }
      incidents.record(["decision": action == .conceal ? "PLCCommitted" : "packetCommitted",
        "sequence": String(sequence), "at": freshNow,
        "headroomMs": headroom(at: freshNow).map { $0 * 1000 } as Any? ?? NSNull(),
        "contiguousEncodedMs": jitter.contiguousPackets * 20])
      if action == .conceal && consecutive == 0 { freezeIncident("PLCStarted", at: freshNow) }
      let packet = jitter.take()
      if packet == nil {
        consecutive += 1; losses += 1; concealed += 1; jitter.markConcealed(sequence)
      } else { consecutive = 0 }
      do {
        var samples = try measured("opusDecode") { try codec!.decode(packet?.payload) }
        passDiagnostics.decoded()
        let first = scheduled == 0
        let last = consecutive >= PlaybackPolicy.maximumConcealedFrames
        let finalBuffer = endSequence == sequence
        let buffer = measured("pcmPreparation") { () -> AVAudioPCMBuffer in
          if first || last || finalBuffer {
            for i in 0..<960 {
              let gain = Float(i) / 959
              for c in 0..<2 { samples[i * 2 + c] *= (last || finalBuffer) ? 1 - gain : gain }
            }
          }
          let buffer = AVAudioPCMBuffer(pcmFormat: g.format, frameCapacity: 960)!
          buffer.frameLength = 960
          for i in 0..<960 {
            buffer.floatChannelData![0][i] = samples[i * 2]
            buffer.floatChannelData![1][i] = samples[i * 2 + 1]
          }
          return buffer
        }
        // Decoding/preparation can be descheduled too; never reuse the pass-start time.
        if first && anchor < AudioWire.now() + 0.010 {
          underruns += 1
          resync("Missed initial rendering deadline", category: "schedulerStarvation"); break
        }
        if !first, let remaining = headroom(at: AudioWire.now()), remaining < -0.020 {
          underruns += 1
          resync("Render queue exhausted during buffer preparation", category: "schedulerStarvation"); break
        }
        measured("bufferScheduling") {
          g.player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
          if first {
            recoveries.update(["scheduledStartHostSeconds": anchor, "playCallAt": AudioWire.now()])
            g.player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: anchor)))
          }
        }
        if first {
          diagnostic("playbackStarted", fields: ["sourcePresentationAnchorMacSeconds": sourceAnchor as Any? ?? NSNull(),
            "sourceSampleBase": sourceSampleBase, "scheduledStartHostSeconds": anchor,
            "playbackEpoch": String(playbackEpoch), "passSequence": passDiagnostics.sequence])
        }
        scheduled += 960; nextPresentation += 0.020; count += 1
        if last { awaitingAfterLoss = true; break }
      } catch {
        onError?(error.localizedDescription)
        resync("Audio decode failed", category: "decodeFailure"); break
      }
    }
    if fadeUntil == nil && !awaitingAfterLoss && jitter.nextPacket != nil,
      let available = headroom(at: AudioWire.now()), available < SchedulingPolicy.target {
      wake.add(data: 1)
    }
  }
  private func emit() { onStats?(statistics()) }
  private func statistics() -> [String: Any] {
    let diagnostics = evidence(at: AudioWire.now())
    let value = latency.snapshot?.value
    return [
      "rendererDiagnostics": diagnostics, "generation": String(generation),
      "state": !active ? "stopped" : playing ? "playing" : "buffering",
      "bufferMs": Double(jitter.packets.count) * 20, "latePackets": jitter.late,
      "duplicates": jitter.duplicates, "rejectedPackets": jitter.rejected,
      "missingAtDeadline": losses, "concealedFrames": concealed, "underruns": underruns,
      "rebufferEvents": rebuffer, "timingErrorMs": errorMs as Any? ?? NSNull(), "rate": rate,
      "outputLatencyMs": value.flatMap { $0.hardware.isFinite ? $0.hardware * 1000 : nil } as Any? ?? NSNull(),
      "pipelineLatencyMs": value.map { $0.pipeline * 1000 } as Any? ?? NSNull(),
    ]
  }
  deinit {
    timer?.cancel(); wake.cancel(); monitor?.cancel()
    if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
  }
}
