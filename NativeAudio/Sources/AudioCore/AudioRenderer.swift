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
  private var errorMs = 0.0
  private var playing = false
  private var configured = false
  private var active = false
  private var lastStats = 0.0
  private var awaitingAfterLoss = false
  private var retiredLate = 0
  private var retiredDuplicates = 0
  private var retiredRejected = 0
  private var measurements = RenderMeasurements()
  private var offsetAdjustment = 0.0
  private var initialLatency = 0.0
  public var onDiagnostic: ((UInt64, Double, String, [String: Any]) -> Void)?
  public var onStats: (([String: Any]) -> Void)?
  public var onEvent: ((String) -> Void)?
  public var onError: ((String) -> Void)?
  public init() {}
  private var latency: Double { max(0, engine.outputNode.presentationLatency) }
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
        self.initialLatency = self.latency
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
      self.jitter.insert(
        packet, hostNow: AudioWire.now() + self.offset, outputLead: self.latency + 0.015)
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
      fadeUntil = AudioWire.now() + 0.020
      onEvent?(reason)
    }
  }
  private func captureReset(_ reason: String, timing: [String: Any] = [:]) {
    let now = AudioWire.now()
    var fields = measurements.json
    fields["reason"] = reason
    fields["timingErrorMs"] = NSNull()
    fields["expectedElapsedSeconds"] = NSNull()
    fields["playerSampleTime"] = NSNull()
    fields["estimatedPlayableAudioMs"] = NSNull()
    if playing, let time = player.lastRenderTime,
      let ptime = player.playerTime(forNodeTime: time), ptime.isSampleTimeValid,
      time.isHostTimeValid {
      let elapsed = AVAudioTime.seconds(forHostTime: time.hostTime)
        - (anchorPresentation - offset - latency)
      fields["expectedElapsedSeconds"] = elapsed
      fields["playerSampleTime"] = ptime.sampleTime
      fields["playerSampleRate"] = ptime.sampleRate
      fields["timingErrorMs"] = (elapsed - Double(ptime.sampleTime) / ptime.sampleRate) * 1000
      fields["estimatedPlayableAudioMs"] = RenderMeasurements.playableMs(
        scheduled: scheduled, sampleTime: ptime.sampleTime, sampleRate: ptime.sampleRate,
        rate: Double(speed.rate)) as Any? ?? NSNull()
    }
    fields["playbackRate"] = speed.rate
    fields["clockOffsetMs"] = offset * 1000
    fields["clockOffsetAdjustmentMs"] = offsetAdjustment * 1000
    fields["outputLatencyMs"] = latency * 1000
    fields["outputLatencyChangeMs"] = (latency - initialLatency) * 1000
    fields["compressedBufferMs"] = jitter.packets.count * 20
    fields["scheduledSamples"] = scheduled
    fields["nextRenderingDeadlineMs"] = playing
      ? (nextPresentation - offset - latency - now) * 1000 as Any : NSNull()
    // Preserve the exact sample pair that triggered a timing/underrun decision.
    fields.merge(timing) { _, captured in captured }
    onDiagnostic?(generation, now, ISO8601DateFormatter().string(from: Date()), fields)
  }
  private func resetPlayback() {
    measurements.resetBoundary()
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
    defer { measurements.pass(AudioWire.now() - now) }
    let hostNow = now + offset
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
    if let time = player.lastRenderTime, let ptime = player.playerTime(forNodeTime: time),
      ptime.isSampleTimeValid, time.isHostTimeValid
    {
      let elapsed =
        AVAudioTime.seconds(forHostTime: time.hostTime) - (anchorPresentation - offset - latency)
      if elapsed > 0.1 {
        let actual = Double(ptime.sampleTime) / ptime.sampleRate
        let error = elapsed - actual
        errorMs = error * 1000
        func capturedTiming() -> [String: Any] {
          ["timingErrorMs": errorMs, "expectedElapsedSeconds": elapsed,
           "playerSampleTime": ptime.sampleTime, "playerSampleRate": ptime.sampleRate,
           "estimatedPlayableAudioMs": RenderMeasurements.playableMs(
             scheduled: scheduled, sampleTime: ptime.sampleTime, sampleRate: ptime.sampleRate,
             rate: Double(speed.rate)) as Any? ?? NSNull()]
        }
        if PlaybackPolicy.mustResync(error: error) {
          resync("Clock/render timing error exceeded 50 ms", timing: capturedTiming())
          reportIfDue(now)
          return
        }
        speed.rate = PlaybackPolicy.rate(error: error)
        if actual > Double(scheduled) / 48000 + 0.020 {
          underruns += 1
          resync("Render underrun", timing: capturedTiming())
          reportIfDue(now)
          return
        }
      }
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
        var samples = try codec!.decode(packet?.payload)
        let first = scheduled == 0
        let last = consecutive >= PlaybackPolicy.maximumConcealedFrames
        let finalBuffer = endSequence != nil && jitter.expected == endSequence! + 1
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
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if first {
          player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: anchor)))
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
      emit()
    }
  }
  private func emit() {
    onStats?([
      "rendererDiagnostics": measurements.json,
      "generation": String(generation),
      "state": !active ? "stopped" : playing ? "playing" : "buffering",
      "bufferMs": Double(jitter.packets.count) * 20, "latePackets": retiredLate + jitter.late,
      "duplicates": retiredDuplicates + jitter.duplicates,
      "rejectedPackets": retiredRejected + jitter.rejected, "missingAtDeadline": losses,
      "concealedFrames": concealed,
      "underruns": underruns, "rebufferEvents": rebuffer, "timingErrorMs": errorMs,
      "rate": speed.rate, "outputLatencyMs": latency * 1000,
    ])
  }
  deinit { timer?.cancel() }
}
