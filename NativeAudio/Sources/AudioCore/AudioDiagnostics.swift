import Foundation

// Bounded, run-scoped evidence. Call only from the owning session queue.
struct AudioDiagnostics {
  private(set) var generation: UInt64 = 0
  private(set) var events = [[String: Any]]()
  private(set) var overflow = 0
  private var next = 1
  mutating func begin(_ value: UInt64) {
    guard generation != value else { return }
    self = AudioDiagnostics()
    generation = value
  }
  mutating func record(_ kind: String, at: Double, utc: String, offset: Double,
    origin: Double, fields: [String: Any] = [:]) {
    guard generation != 0 else { return }
    var event = fields
    event["sequence"] = next
    event["generation"] = String(generation)
    event["kind"] = kind
    event["at"] = utc
    event["monotonicSeconds"] = at
    event["clockOffsetMs"] = offset * 1000
    event["streamSeconds"] = at + offset - origin
    next += 1
    events.append(event)
    if events.count > 32 { events.removeFirst(); overflow += 1 }
  }
  var json: [String: Any] {
    ["events": Array(events.suffix(8)), "retentionOverflow": overflow,
     "latestSequence": next - 1]
  }
}

struct ReceivedAudioDiagnostics {
  private(set) var events = [[String: Any]]()
  private(set) var overflow = 0
  private(set) var gaps = 0
  private var highest = 0
  mutating func merge(_ incoming: [[String: Any]], generation: UInt64) {
    for event in incoming.sorted(by: {
      ($0["sequence"] as? Int ?? 0) < ($1["sequence"] as? Int ?? 0)
    }) {
      guard event["generation"] as? String == String(generation),
        let sequence = event["sequence"] as? Int, sequence > highest else { continue }
      gaps += max(0, sequence - highest - 1)
      highest = sequence
      events.append(event)
      if events.count > 256 { events.removeFirst(); overflow += 1 }
    }
  }
  func json(_ summary: [String: Any]) -> [String: Any] {
    var value = summary
    value["events"] = events
    value["hostRetentionOverflow"] = overflow
    value["observedSequenceGaps"] = gaps
    return value
  }
}

struct RenderMeasurements {
  private var previousTick: Double?
  private(set) var lastIntervalMs = 0.0
  private(set) var maxIntervalMs = 0.0
  private(set) var maxSinceResetMs = 0.0
  private var counts = [0, 0, 0]
  private(set) var maxPassMs = 0.0
  private(set) var lastPassMs = 0.0
  private(set) var maxPacketQueueMs = 0.0
  private var lastPacketQueueMs = 0.0
  mutating func tick(_ now: Double) {
    if let previous = previousTick {
      lastIntervalMs = max(0, now - previous) * 1000
      maxIntervalMs = max(maxIntervalMs, lastIntervalMs)
      maxSinceResetMs = max(maxSinceResetMs, lastIntervalMs)
      for (i, threshold) in [20.0, 50, 100].enumerated() {
        if lastIntervalMs > threshold { counts[i] += 1 }
      }
    }
    previousTick = now
  }
  mutating func pass(_ seconds: Double) {
    lastPassMs = max(0, seconds) * 1000
    maxPassMs = max(maxPassMs, lastPassMs)
  }
  mutating func packetQueue(_ seconds: Double) {
    lastPacketQueueMs = max(0, seconds) * 1000
    maxPacketQueueMs = max(maxPacketQueueMs, lastPacketQueueMs)
  }
  mutating func resetBoundary() { maxSinceResetMs = 0; previousTick = nil }
  static func playableMs(scheduled: Int, sampleTime: Int64?, sampleRate: Double,
    rate: Double) -> Double? {
    guard let sampleTime = sampleTime, sampleRate.isFinite, sampleRate > 0,
      rate.isFinite, rate > 0 else { return nil }
    return max(0, Double(scheduled) / 48000 - Double(sampleTime) / sampleRate) / rate * 1000
  }
  var json: [String: Any] {
    ["lastTimerIntervalMs": lastIntervalMs, "maxTimerIntervalMs": maxIntervalMs,
     "maxTimerIntervalSinceResetMs": maxSinceResetMs,
     "timerGapThresholdsMs": [20, 50, 100], "timerGapCounts": counts,
     "lastSchedulingPassMs": lastPassMs, "maxSchedulingPassMs": maxPassMs,
     "maxPacketQueueDelayMs": maxPacketQueueMs, "lastPacketQueueDelayMs": lastPacketQueueMs]
  }
}

// Trim evidence, not playback state, to satisfy the existing control-frame limit.
enum DiagnosticControlFrame {
  static func prepare(_ object: [String: Any], omissions: inout Int) -> [String: Any] {
    guard var stats = object["stats"] as? [String: Any],
      var diagnostics = stats["diagnostics"] as? [String: Any] else { return object }
    var result = object
    var events = diagnostics["events"] as? [[String: Any]] ?? []
    while true {
      diagnostics["events"] = events
      diagnostics["transportOmissions"] = omissions
      stats["diagnostics"] = diagnostics
      result["stats"] = stats
      if let data = try? JSONSerialization.data(withJSONObject: result), data.count <= 16384 {
        return result
      }
      guard !events.isEmpty else { return result }
      events.removeFirst()
      omissions += 1
    }
  }
}
