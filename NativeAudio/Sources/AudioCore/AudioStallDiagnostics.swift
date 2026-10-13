import Foundation

// Measurements use wall time on the existing owning queues, never audio callbacks.
struct RendererPassDiagnostics {
  private(set) var sequence = 0
  private var began: Double?
  private var stages = [String: Double]()
  private var frames = 0
  private var decodedFrames = 0
  private var passMaxima = [String: Double]()
  private var completed = [String: Any]()
  private var maxima = [String: Double]()
  private var counts = [String: Int]()
  private var slowCount = 0
  private var suppressed = 0
  private var lastSlowEvent: Double?
  mutating func begin(at now: Double) { sequence += 1; began = now; stages = [:]; frames = 0 }
  mutating func stage(_ name: String, seconds: Double) {
    guard seconds.isFinite else { return }
    let ms = max(0, seconds) * 1000
    stages[name, default: 0] += ms
    maxima[name] = max(maxima[name, default: 0], ms)
    counts[name, default: 0] += 1
  }
  mutating func decoded() { frames += 1; decodedFrames += 1 }
  func partial(at now: Double) -> [String: Any] {
    ["sequence": sequence, "startedMonotonicSeconds": began as Any? ?? NSNull(),
     "elapsedMs": began.map { max(0, now - $0) * 1000 } as Any? ?? NSNull(),
     "stageDurationsMs": stages, "decodedFrames": frames]
  }
  mutating func finish(at now: Double) -> [String: Any]? {
    guard let began = began else { return nil }
    for (name, ms) in stages { passMaxima[name] = max(passMaxima[name, default: 0], ms) }
    completed = partial(at: now)
    completed["durationMs"] = max(0, now - began) * 1000
    self.began = nil
    guard now - began > 0.020 else { return nil }
    slowCount += 1
    guard lastSlowEvent.map({ now - $0 >= 1 }) ?? true else { suppressed += 1; return nil }
    lastSlowEvent = now
    return completed
  }
  func json(at now: Double) -> [String: Any] {
    ["completedPass": completed, "currentPartialPass": began == nil ? NSNull() : partial(at: now) as Any,
     "stageMaxCallMs": maxima, "stageMaxPassMs": passMaxima, "stageCallCounts": counts,
     "passCount": sequence, "decodedFrames": decodedFrames,
     "slowPassCount": slowCount, "suppressedSlowPassEvents": suppressed]
  }
}

struct TimingObservationWindow {
  private(set) var observations = [[String: Any]]()
  private var last: Double?
  func due(at now: Double) -> Bool { now.isFinite && (last.map { now - $0 >= 0.100 } ?? true) }
  mutating func append(at now: Double, fields: [String: Any]) {
    guard due(at: now) else { return }
    var value = fields
    value["capturedMonotonicSeconds"] = now
    observations.append(value)
    if observations.count > 16 { observations.removeFirst() }
    last = now
  }
}

struct TransportTimerDiagnostics {
  private var previous: Double?
  private var maximum = 0.0
  private var counts = [0, 0, 0]
  mutating func tick(_ now: Double) {
    if let previous = previous {
      let ms = max(0, now - previous) * 1000
      maximum = max(maximum, ms)
      for (i, threshold) in [150.0, 250, 500].enumerated() { if ms > threshold { counts[i] += 1 } }
    }
    previous = now
  }
  var json: [String: Any] {
    ["expectedIntervalMs": 100, "maxIntervalMs": maximum,
     "gapThresholdsMs": [150, 250, 500], "gapCounts": counts]
  }
}

struct SenderDiagnostics {
  private var stages = [String: Double]()
  private var counts = [String: Int]()
  private var excessCounts = [String: [Int]]()
  mutating func record(_ name: String, seconds: Double) {
    guard seconds.isFinite else { return }
    stages[name] = max(stages[name, default: 0], max(0, seconds) * 1000)
    counts[name, default: 0] += 1
    var excess = excessCounts[name] ?? [0, 0, 0]
    for (i, threshold) in [0.020, 0.050, 0.100].enumerated() { if seconds > threshold { excess[i] += 1 } }
    excessCounts[name] = excess
  }
  var json: [String: Any] { ["maxDurationsMs": stages, "measurementCounts": counts,
    "excessThresholdsMs": [20, 50, 100], "excessCounts": excessCounts] }
}

enum AudioTestMarker {
  static let labels = ["background": "Background app", "foreground": "Return to app",
    "lock": "Lock phone", "wakeLocked": "Wake screen while locked", "unlock": "Unlock phone"]
  static func event(_ marker: String, at: Double, utc: String, origin: Double) -> [String: Any]? {
    guard let label = labels[marker], at.isFinite, origin.isFinite else { return nil }
    return ["kind": "userReportedTransition", "marker": marker, "message": label,
      "at": utc, "monotonicSeconds": at, "streamSeconds": at - origin,
      "timingAccuracy": "approximate user action"]
  }
}
