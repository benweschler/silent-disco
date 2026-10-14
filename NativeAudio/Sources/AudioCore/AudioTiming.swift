import Foundation

struct PlaybackLatency {
  let hardware: Double
  let pipeline: Double
  let ioBuffer: Double?
  var valid: Bool { pipeline.isFinite && pipeline >= 0 }
  var json: [String: Any] {
    ["outputLatencyMs": hardware.isFinite ? hardware * 1000 as Any : NSNull(),
     "pipelineLatencyMs": valid ? pipeline * 1000 as Any : NSNull(),
     "ioBufferDurationMs": ioBuffer.flatMap { $0.isFinite ? $0 * 1000 : nil } as Any? ?? NSNull()]
  }
}

struct PlaybackTiming {
  let nodeHost: Double?
  let sampleTime: Int64?
  let sampleRate: Double
  let offset: Double
  let presentationAnchor: Double
  let latency: PlaybackLatency
  var nodeSampleTime: Int64? = nil
  var nodeSampleRate: Double? = nil
  var sourceSampleBase: Int64 = 0
  var valid: Bool {
    guard let host = nodeHost, sampleTime != nil else { return false }
    return [host, sampleRate, offset, presentationAnchor].allSatisfy(\.isFinite)
      && sampleRate > 0 && latency.valid
      && (Double(sampleTime!) / sampleRate).isFinite
      && (host + offset + latency.pipeline - presentationAnchor).isFinite
  }
  var actual: Double? { valid ? Double(sampleTime!) / sampleRate : nil }
  var elapsed: Double? { valid ? nodeHost! + offset + latency.pipeline - presentationAnchor : nil }
  func hasUnderrun(scheduled: Int) -> Bool {
    guard let actual = actual, let elapsed = elapsed, elapsed > 0.1 else { return false }
    return actual > Double(scheduled) / 48000 + 0.020
  }
  var error: Double? {
    guard let actual = actual, let elapsed = elapsed else { return nil }
    let result = elapsed - (Double(sourceSampleBase) / 48000 + actual)
    return result.isFinite ? result : nil
  }
  func json(scheduled: Int, rate: Double) -> [String: Any] {
    var fields = latency.json
    fields["nodeHostTimeValid"] = nodeHost?.isFinite == true
    fields["playerSampleTimeValid"] = sampleTime != nil && sampleRate.isFinite && sampleRate > 0
    fields["nodeHostSeconds"] = nodeHost.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull()
    fields["playerSampleTime"] = sampleTime as Any? ?? NSNull()
    fields["sourceSampleBase"] = sourceSampleBase
    fields["playerSampleRate"] = sampleRate.isFinite ? sampleRate as Any : NSNull()
    fields["expectedElapsedSeconds"] = elapsed as Any? ?? NSNull()
    fields["timingErrorMs"] = error.map { $0 * 1000 } as Any? ?? NSNull()
    fields["hardwareOnlyTimingErrorMs"] = valid && latency.hardware.isFinite
      ? (nodeHost! + offset + latency.hardware - presentationAnchor
        - Double(sourceSampleBase) / 48000 - actual!) * 1000 as Any : NSNull()
    fields["estimatedPlayableAudioMs"] = RenderMeasurements.playableMs(
      scheduled: scheduled, sampleTime: valid ? sampleTime : nil, sampleRate: sampleRate,
      rate: rate) as Any? ?? NSNull()
    return fields
  }
}

struct SustainedTimingError {
  private var began: Double?
  private var previous: Double?
  private var sign = 0
  struct Decision {
    let reset: Bool
    let transition: String?
  }
  mutating func clear() { self = SustainedTimingError() }
  mutating func observe(error: Double?, at now: Double) -> Decision {
    guard now.isFinite, let error = error, error.isFinite else {
      let pending = began != nil
      clear()
      return Decision(reset: false, transition: pending ? "timingCandidateInvalidated" : nil)
    }
    guard abs(error) > 0.050 else {
      let pending = began != nil
      clear()
      return Decision(reset: false, transition: pending ? "timingCandidateRecovered" : nil)
    }
    let nextSign = error > 0 ? 1 : -1
    let gap = previous.map { now - $0 }
    let replace = sign != nextSign || gap.map { $0 > 0.100 || $0 < 0 } == true
    let wasPending = began != nil
    if began == nil || replace {
      began = now
      sign = nextSign
      previous = now
      return Decision(reset: false, transition: wasPending ? "timingCandidateReplaced" : "timingCandidateStarted")
    }
    previous = now
    if now - began! >= 0.200 {
      clear()
      return Decision(reset: true, transition: "timingCandidateSustained")
    }
    return Decision(reset: false, transition: nil)
  }
}
