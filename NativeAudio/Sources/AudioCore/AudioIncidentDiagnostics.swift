import Foundation
import os

/// Software observations on owning queues; these intervals do not measure acoustic silence.
struct AudioCallMeasurements {
  private var aggregate = SenderDiagnostics()
  private var slow = [[String: Any]]()
  private var omitted = 0
  mutating func record(_ name: String, site: String, start: Double, end: Double,
    graph: UInt64, playback: UInt64) {
    aggregate.record(name, seconds: end - start)
    guard end - start >= 0.020 else { return }
    slow.append(["call": name, "site": site, "start": start, "end": end,
      "graphEpoch": String(graph), "playbackEpoch": String(playback)])
    if slow.count > 16 { slow.removeFirst(); omitted += 1 }
  }
  var json: [String: Any] { ["aggregate": aggregate.json, "slowCalls": slow, "omittedSlowCalls": omitted] }
}

enum AudioTrace {
  static let enabled = ProcessInfo.processInfo.environment["SD_AUDIO_TRACE"] == "1"
    || UserDefaults.standard.bool(forKey: "SDAudioTrace")
  static let log = OSLog(subsystem: "dev.silentdisco.audio", category: "Pipeline")
  static func interval<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
    guard enabled else { return try work() }
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "Audio operation", signpostID: id, "%{public}@", name as NSString)
    defer { os_signpost(.end, log: log, name: "Audio operation", signpostID: id) }
    return try work()
  }
}

struct PacketIncidentEvidence {
  private(set) var ring = [[String: Any]]()
  private(set) var windows = [[String: Any]]()
  private var next = 1
  private var ringEvictions = 0
  private var windowEvictions = 0
  mutating func record(_ fields: [String: Any]) {
    var fields = fields; fields["evidenceSequence"] = next; next += 1
    ring.append(fields)
    if ring.count > 256 { ring.removeFirst(); ringEvictions += 1 }
  }
  @discardableResult mutating func freeze(_ reason: String, at: Double) -> [String: Any] {
    let window: [String: Any] = ["reason": reason, "at": at, "entries": Array(ring.suffix(32))]
    windows.append(window)
    if windows.count > 8 { windows.removeFirst(); windowEvictions += 1 }
    return window
  }
  var json: [String: Any] { ["windows": windows.map { window in
    var summary = window; let entries = summary.removeValue(forKey: "entries") as? [[String: Any]] ?? []
    summary["entryCount"] = entries.count
    summary["firstEvidenceSequence"] = entries.first?["evidenceSequence"] ?? 0
    summary["lastEvidenceSequence"] = entries.last?["evidenceSequence"] ?? 0
    return summary
  }, "ringEvictions": ringEvictions,
    "windowEvictions": windowEvictions, "firstRetainedEvidenceSequence": ring.first?["evidenceSequence"] ?? next,
    "latestEvidenceSequence": next - 1] }
}

struct RecoveryTimeline {
  private(set) var records = [[String: Any]]()
  private var current: [String: Any]?
  private var next = 1
  private var evictions = 0
  mutating func begin(reason: String, category: String, at: Double, fields: [String: Any]) {
    if current != nil { update(["supersededAt": at]); finish() }
    current = fields
    update(["recoveryID": next, "reason": reason, "category": category, "decisionAt": at,
      "measurement": "software observations; acoustic silence unmeasured"])
    next += 1
  }
  mutating func update(_ fields: [String: Any]) {
    guard current != nil else { return }
    current!.merge(fields) { _, new in new }
    if let stop = current?["stopEnteredAt"] as? Double, let decision = current?["decisionAt"] as? Double {
      current!["decisionToStopMs"] = (stop - decision) * 1000
    }
  }
  mutating func progressed(at: Double) -> [String: Any]? {
    guard current != nil, current?["playCallAt"] != nil else { return nil }
    update(["firstObservedProgressAt": at])
    if let stop = current?["stopReturnedAt"] as? Double { update(["stopToObservedProgressMs": (at - stop) * 1000]) }
    return finish()
  }
  @discardableResult mutating func finish() -> [String: Any]? {
    guard let current = current else { return nil }
    records.append(current); self.current = nil
    if records.count > 16 { records.removeFirst(); evictions += 1 }
    return current
  }
  var json: [String: Any] { ["records": records, "current": current as Any? ?? NSNull(), "evictions": evictions] }
}

/// Final counters are immutable for a generation. Detailed evidence can continue arriving.
struct FinalListenerSnapshot {
  private(set) var stats = [String: Any]()
  private(set) var final = false
  private(set) var diagnosticSequence = 0
  mutating func accept(_ stats: [String: Any], final: Bool, sequence: Int) {
    guard !self.final else { return }
    self.stats = stats; self.final = final
    if final { diagnosticSequence = sequence }
  }
}

/// Off-queue probe distinguishes transport-queue backlog from receive callback spacing.
/// The probe owns its flag; at most one queued measurement can be outstanding.
final class SessionQueueProbe {
  private let probeQueue = DispatchQueue(label: "dev.silentdisco.audio.queueProbe", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var outstanding = false
  func start(target: DispatchQueue, record: @escaping (Double) -> Void) {
    let timer = DispatchSource.makeTimerSource(queue: probeQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
    timer.setEventHandler { [weak self] in
      guard let self = self, !self.outstanding else { return }
      self.outstanding = true
      let enqueued = AudioWire.now()
      target.async { [weak self] in
        record(AudioWire.now() - enqueued)
        self?.probeQueue.async { [weak self] in self?.outstanding = false }
      }
    }
    self.timer = timer; timer.resume()
  }
  deinit { timer?.cancel() }
}

enum AudioReportReadiness {
  static func evaluate(ids: Set<String>, rows: [[String: Any]]) -> [String: Any] {
    let missingRows = ids.subtracting(Set(rows.compactMap { $0["id"] as? String }))
    let missing = rows.filter { $0["finalCounters"] as? Bool != true }.compactMap { $0["id"] as? String }
    let pending = rows.filter { $0["finalCounters"] as? Bool == true && $0["diagnosticDeliveryComplete"] as? Bool != true }.compactMap { $0["id"] as? String }
    let ready = !ids.isEmpty && missingRows.isEmpty && missing.isEmpty && pending.isEmpty
    return ["ready": ready, "missingFinalListeners": missing + missingRows.sorted(),
      "pendingDiagnosticListeners": pending, "stage": ids.isEmpty ? "noParticipants"
        : !missing.isEmpty || !missingRows.isEmpty ? "listenerFinalSnapshot"
        : !pending.isEmpty ? "diagnosticDelivery" : "complete"]
  }
}
