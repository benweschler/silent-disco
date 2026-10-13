import AVFoundation
import Foundation

// All state belongs to this queue; no locks, allocation, codec work or I/O in render callbacks.
public final class AudioRenderer {
  private let queue = DispatchQueue(label: "dev.silentdisco.audio.render", qos: .userInitiated)
  private var engine = AVAudioEngine()
  private var player = AVAudioPlayerNode()
  private var speed = AVAudioUnitVarispeed()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var codec: AudioCodec?
  private var jitter = AudioJitterBuffer()
  private var timer: DispatchSourceTimer?
  private var generation: UInt64 = 0
  private var offset = 0.0
  private var anchor = 0.0
  private var anchorPresentation = 0.0
  private var fadeUntil: Double?
  private var endSequence: UInt64?
  private var nextPresentation = 0.0
  private var scheduled = 0
  private var concealed = 0
  private var losses = 0
  private var consecutive = 0
  private var underruns = 0
  private var rebuffer = 0
  private var errorMs: Double?
  private var playing = false
  private var configured = false
  private var active = false
  private var lastStats = 0.0
  private var awaitingAfterLoss = false
  private var retiredLate = 0
  private var retiredDuplicates = 0
  private var retiredRejected = 0
  private var measurements = RenderMeasurements()
  private var passDiagnostics = RendererPassDiagnostics()
  private var observations = TimingObservationWindow()
  private func measured<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
    let start = AudioWire.now()
    defer { passDiagnostics.stage(stage, seconds: AudioWire.now() - start) }
    return try work()
  }
  private func observeTiming(_ timing: PlaybackTiming, at now: Double) {
    guard observations.due(at: now) else { return }
    var fields = timing.json(scheduled: scheduled, rate: Double(speed.rate))
    fields["playerNodeSampleTime"] = timing.nodeSampleTime as Any? ?? NSNull()
    fields["playerNodeSampleRate"] = timing.nodeSampleRate as Any? ?? NSNull()
    let output = engine.outputNode.lastRenderTime
    fields["outputNodeHostSeconds"] = output.flatMap { $0.isHostTimeValid ? AVAudioTime.seconds(forHostTime: $0.hostTime) : nil } as Any? ?? NSNull()
    fields["outputNodeSampleTime"] = output.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil } as Any? ?? NSNull()
    fields["outputNodeSampleRate"] = output.flatMap { $0.sampleRate.isFinite ? $0.sampleRate : nil } as Any? ?? NSNull()
    fields["clockOffsetMs"] = offset * 1000
    fields["playbackRate"] = speed.rate
    fields["scheduledSamples"] = scheduled
    fields["presentationAnchorMacSeconds"] = anchorPresentation
    observations.append(at: now, fields: fields)
  }
  private var offsetAdjustment = 0.0
  private var initialLatency = 0.0
  private var initialPipelineLatency = 0.0
  private var timingDecision = SustainedTimingError()
  private var latestTiming: PlaybackTiming?
  private var passLatency: PlaybackLatency?
  public var onDiagnostic: ((UInt64, Double, String, [String: Any]) -> Void)?
  public var onStats: (([String: Any]) -> Void)?
  public var onEvent: ((String) -> Void)?
  public var onError: ((String) -> Void)?
  public init() {}
  private func readLatency() -> PlaybackLatency {
    #if os(iOS)
      let ioBuffer: Double? = AVAudioSession.sharedInstance().ioBufferDuration
    #else
      let ioBuffer: Double? = nil
    #endif
    return PlaybackLatency(hardware: engine.outputNode.presentationLatency,
      pipeline: player.outputPresentationLatency, ioBuffer: ioBuffer)
  }
  private func readTiming(_ latency: PlaybackLatency) -> PlaybackTiming {
    let node = player.lastRenderTime
    let position = node.flatMap { player.playerTime(forNodeTime: $0) }
    return PlaybackTiming(
      nodeHost: node.flatMap { $0.isHostTimeValid ? AVAudioTime.seconds(forHostTime: $0.hostTime) : nil },
      sampleTime: position.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil },
      sampleRate: position?.sampleRate ?? 0, offset: offset,
      presentationAnchor: anchorPresentation, latency: latency,
      nodeSampleTime: node.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil },
      nodeSampleRate: node.flatMap { $0.sampleRate.isFinite ? $0.sampleRate : nil })
  }
  public func start(generation: UInt64, offset: Double) {
    queue.async {
      do {
        let sameRun = self.generation == generation
        self.stopInternal()
        self.endSequence = nil
        self.generation = generation
        self.offset = offset
        if sameRun {
          self.retiredLate += self.jitter.late
          self.retiredDuplicates += self.jitter.duplicates
          self.retiredRejected += self.jitter.rejected
          self.rebuffer += 1
        } else {
          self.measurements = RenderMeasurements()
          self.passDiagnostics = RendererPassDiagnostics()
          self.observations = TimingObservationWindow()
          self.offsetAdjustment = 0
          self.retiredLate = 0
          self.retiredDuplicates = 0
          self.retiredRejected = 0
          self.concealed = 0
          self.losses = 0
          self.underruns = 0
          self.rebuffer = 0
        }
        self.jitter = AudioJitterBuffer()
        self.codec = try AudioCodec()
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        self.speed = AVAudioUnitVarispeed()
        self.engine.attach(self.player)
        self.engine.attach(self.speed)
        self.engine.connect(self.player, to: self.speed, format: self.format)
        self.engine.connect(self.speed, to: self.engine.mainMixerNode, format: self.format)
        self.engine.prepare()
        try self.engine.start()
        let latency = self.readLatency()
        self.initialLatency = latency.hardware
        self.initialPipelineLatency = latency.pipeline
        self.timingDecision.clear()
        self.latestTiming = nil
        self.errorMs = nil
        self.measurements.resetBoundary()
        self.configured = true
        self.active = true
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
      } catch {
        self.stopInternal()
        self.onError?(error.localizedDescription)
      }
    }
  }
  public func finish(after sequence: UInt64?) {
    queue.async {
      self.endSequence = sequence
      if sequence == nil {
        self.stopInternal()
        self.emit()
      }
    }
  }
  public func clock(_ value: Double) {
    queue.async {
      self.offsetAdjustment = value - self.offset
      self.offset = value
    }
  }
  public func receive(_ packet: AudioPacket) {
    let enqueued = AudioWire.now()
    queue.async {
      guard self.active, packet.generation == self.generation else { return }
      self.measurements.packetQueue(AudioWire.now() - enqueued)
      let latency = self.readLatency()
      guard latency.valid else { return }
      self.jitter.insert(
        packet, hostNow: AudioWire.now() + self.offset, outputLead: latency.pipeline + 0.015)
    }
  }
  public func stop(completion: (() -> Void)? = nil) {
    queue.async {
      self.stopInternal()
      self.emit()
      completion?()
    }
  }
  private func stopInternal() {
    if active && configured { captureReset("Renderer stopped or restarted") }
    timer?.cancel()
    timer = nil
    timingDecision.clear()
    latestTiming = nil
    errorMs = nil
    player.stop()
    engine.stop()
    active = false
    playing = false
    jitter.reset()
    configured = false
    awaitingAfterLoss = false
    fadeUntil = nil
  }
  private func resync(_ reason: String = "Rebuffering after missing audio",
    timing: [String: Any] = [:]) {
    if fadeUntil == nil {
      captureReset(reason, timing: timing)
      timingDecision.clear()
      fadeUntil = AudioWire.now() + 0.020
      onEvent?(reason)
    }
  }
  private func captureReset(_ reason: String, timing: [String: Any] = [:]) {
    let now = AudioWire.now()
    var fields = measurements.json
    fields["passDiagnostics"] = passDiagnostics.json(at: now)
    fields["timingObservations"] = observations.observations
    fields["reason"] = reason
    let latency = passLatency ?? readLatency()
    if playing {
      fields.merge(readTiming(latency).json(scheduled: scheduled, rate: Double(speed.rate))) { _, new in new }
    } else {
      fields.merge(PlaybackTiming(nodeHost: nil, sampleTime: nil, sampleRate: 0,
        offset: offset, presentationAnchor: anchorPresentation, latency: latency)
        .json(scheduled: scheduled, rate: Double(speed.rate))) { _, new in new }
    }
    fields["playbackRate"] = speed.rate
    fields["clockOffsetMs"] = offset * 1000
    fields["clockOffsetAdjustmentMs"] = offsetAdjustment * 1000
    fields["outputLatencyChangeMs"] = latency.hardware.isFinite && initialLatency.isFinite
      ? (latency.hardware - initialLatency) * 1000 as Any : NSNull()
    fields["pipelineLatencyChangeMs"] = latency.valid && initialPipelineLatency.isFinite
      ? (latency.pipeline - initialPipelineLatency) * 1000 as Any : NSNull()
    fields["compressedBufferMs"] = jitter.packets.count * 20
    fields["scheduledSamples"] = scheduled
    fields["nextRenderingDeadlineMs"] = playing && latency.valid
      ? (nextPresentation - offset - latency.pipeline - now) * 1000 as Any : NSNull()
    // Preserve the exact sample pair that triggered a timing/underrun decision.
    fields.merge(timing) { _, captured in captured }
    onDiagnostic?(generation, now, ISO8601DateFormatter().string(from: Date()), fields)
  }
  private func resetPlayback() {
    measurements.resetBoundary()
    timingDecision.clear()
    latestTiming = nil
    errorMs = nil
    fadeUntil = nil
    player.stop()
    engine.mainMixerNode.outputVolume = 1
    playing = false
    jitter.reset()
    codec?.resetDecoder()
    scheduled = 0
    consecutive = 0
    speed.rate = 1
    rebuffer += 1
    awaitingAfterLoss = false
  }
  private func tick() {
    guard active, configured else { return }
    let now = AudioWire.now()
    measurements.tick(now)
    passDiagnostics.begin(at: now)
    defer {
      let end = AudioWire.now()
      measurements.pass(end - now)
      if let pass = passDiagnostics.finish(at: end) {
        onDiagnostic?(generation, end, ISO8601DateFormatter().string(from: Date()),
          ["diagnosticKind": "slowRendererPass", "pass": pass, "clockOffsetMs": offset * 1000])
      }
    }
    let context = measured("latencyRead") { readLatency() }
    passLatency = context
    defer { passLatency = nil }
    let hostNow = now + offset
    guard context.valid else {
      let timing = measured("timestampRead") { readTiming(context) }
      measured("observationRead") { observeTiming(timing, at: now) }
      let decision = timingDecision.observe(error: nil, at: now)
      errorMs = nil
      latestTiming = nil
      if let transition = decision.transition { timingEvent(transition, timing: timing) }
      reportIfDue(now)
      return
    }
    let latency = context.pipeline
    if let deadline = fadeUntil {
      engine.mainMixerNode.outputVolume = Float(max(0, min(1, (deadline - now) / 0.020)))
      if now >= deadline { resetPlayback() }
      reportIfDue(now)
      return
    }
    if !playing {
      jitter.discard(before: hostNow + latency + 0.030)
      guard let first = jitter.first, jitter.packets.count >= 3 else {
        reportIfDue(now)
        return
      }
      jitter.begin(at: first.sequence)
      nextPresentation = first.presentation
      anchorPresentation = first.presentation
      anchor = first.presentation - offset - latency
      scheduled = 0
      consecutive = 0
      playing = true

    }
    if let end = endSequence, let next = jitter.expected, next > end {
      reportIfDue(now)
      return
    }
    if awaitingAfterLoss {
      if hostNow >= nextPresentation - latency { resync() }
      reportIfDue(now)
      return
    }
    let timing = measured("timestampRead") { readTiming(context) }
    measured("observationRead") { observeTiming(timing, at: now) }
    latestTiming = timing
    errorMs = timing.error.map { $0 * 1000 }
    // Starvation is independent of timestamp-error confirmation.
    if timing.hasUnderrun(scheduled: scheduled) {
      underruns += 1
      resync("Render underrun", timing: timing.json(scheduled: scheduled, rate: Double(speed.rate)))
      reportIfDue(now)
      return
    }
    let error = timing.elapsed.map { $0 > 0.1 } == true ? timing.error : nil
    let decision = timingDecision.observe(error: error, at: now)
    if let transition = decision.transition { timingEvent(transition, timing: timing) }
    if decision.reset {
      resync("Sustained clock/render timing error exceeded 50 ms",
        timing: timing.json(scheduled: scheduled, rate: Double(speed.rate)))
      reportIfDue(now)
      return
    }
    if let error = error {
      measured("rateChange") { speed.rate = abs(error) > 0.050 ? 1 : PlaybackPolicy.rate(error: error) }
    }
    // Schedule only a short PCM horizon. The larger lead stays encoded in the jitter buffer.
    var count = 0
    while nextPresentation - offset - latency < now + 0.100 && count < 6 {
      if let end = endSequence, let next = jitter.expected, next > end { break }
      if nextPresentation - offset - latency < now + 0.010 {
        underruns += 1
        resync("Missed rendering deadline")
        break
      }
      let packet = jitter.take()
      if packet == nil {
        consecutive += 1
        losses += 1
        concealed += 1
      } else {
        consecutive = 0
      }
      do {
        var samples = try measured("opusDecode") { try codec!.decode(packet?.payload) }
        passDiagnostics.decoded()
        let first = scheduled == 0
        let last = consecutive >= PlaybackPolicy.maximumConcealedFrames
        let finalBuffer = endSequence != nil && jitter.expected == endSequence! + 1
        let buffer = measured("pcmPreparation") { () -> AVAudioPCMBuffer in
          if first || last || finalBuffer {
            for i in 0..<960 {
              let gain = Float(i) / 959
              for c in 0..<2 { samples[i * 2 + c] *= (last || finalBuffer) ? 1 - gain : gain }
            }
          }
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
          buffer.frameLength = 960
          for i in 0..<960 {
            buffer.floatChannelData![0][i] = samples[i * 2]
            buffer.floatChannelData![1][i] = samples[i * 2 + 1]
          }
          return buffer
        }
        measured("bufferScheduling") {
          player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
          if first {
            player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: anchor)))
            onDiagnostic?(generation, AudioWire.now(), ISO8601DateFormatter().string(from: Date()),
              ["diagnosticKind": "playbackStarted", "presentationAnchorMacSeconds": anchorPresentation,
               "scheduledStartHostSeconds": anchor, "clockOffsetMs": offset * 1000,
               "passSequence": passDiagnostics.sequence])
          }
        }
        scheduled += 960
        nextPresentation += 0.020
        count += 1
        if last {
          awaitingAfterLoss = true
          break
        }
      } catch {
        onError?(error.localizedDescription)
        resync()
        break
      }
    }
    reportIfDue(now)
  }
  private func reportIfDue(_ now: Double) {
    if now - lastStats >= 1 {
      lastStats = now
      measured("statistics") { emit() }
    }
  }
  private func timingEvent(_ kind: String, timing: PlaybackTiming) {
    var fields = timing.json(scheduled: scheduled, rate: Double(speed.rate))
    fields["diagnosticKind"] = kind
    if kind == "timingCandidateStarted" || kind == "timingCandidateSustained" {
      fields["timingObservations"] = observations.observations
    }
    fields["clockOffsetMs"] = offset * 1000
    onDiagnostic?(generation, AudioWire.now(), ISO8601DateFormatter().string(from: Date()), fields)
  }
  private func emit() {
    var diagnostics = measurements.json
    diagnostics["passDiagnostics"] = passDiagnostics.json(at: AudioWire.now())
    if let timing = latestTiming {
      diagnostics.merge(timing.json(scheduled: scheduled, rate: Double(speed.rate))) { _, new in new }
    }
    let latency = passLatency ?? readLatency()
    onStats?([
      "rendererDiagnostics": diagnostics,
      "generation": String(generation),
      "state": !active ? "stopped" : playing ? "playing" : "buffering",
      "bufferMs": Double(jitter.packets.count) * 20, "latePackets": retiredLate + jitter.late,
      "duplicates": retiredDuplicates + jitter.duplicates,
      "rejectedPackets": retiredRejected + jitter.rejected, "missingAtDeadline": losses,
      "concealedFrames": concealed,
      "underruns": underruns, "rebufferEvents": rebuffer, "timingErrorMs": errorMs as Any? ?? NSNull(),
      "rate": speed.rate,
      "outputLatencyMs": latency.hardware.isFinite ? latency.hardware * 1000 as Any : NSNull(),
      "pipelineLatencyMs": latency.valid ? latency.pipeline * 1000 as Any : NSNull(),
    ])
  }
  deinit { timer?.cancel() }
}
