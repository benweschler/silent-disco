import Foundation

enum AudioLeadPolicy {
  static let choices = [500, 750, 1000, 1250]
  static let defaultMs = 1250
  static func maximum(_ advertised: Int?) -> Int {
    guard let advertised = advertised, advertised >= 500 else { return 1000 }
    return min(1250, advertised)
  }
  static func supports(_ lead: Double, maximum: Int) -> Bool {
    lead.isFinite && lead * 1000 <= Double(maximum) + 0.001
  }
}

/// Transport and scheduler threads only. No lock is used by an audio render callback.
final class AudioPacketMailbox {
  struct Entry { let packet: AudioPacket; let callbackAt: Double }
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var entries = [UInt64: Entry]()
  private var stored = 0
  private var overflow = 0
  private var duplicates = 0
  private var rejections = [[String: Any]]()
  private var rejectionEvictions = 0
  func begin(_ generation: UInt64, stored: Int = 0, resetCounters: Bool = true) {
    lock.lock(); defer { lock.unlock() }
    self.generation = generation; entries.removeAll(keepingCapacity: true); self.stored = stored
    if resetCounters { overflow = 0; duplicates = 0; rejections = []; rejectionEvictions = 0 }
  }
  @discardableResult func offer(_ packet: AudioPacket, at now: Double) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard packet.generation == generation, generation != 0 else { return false }
    guard entries[packet.sequence] == nil else {
      duplicates += 1; reject(packet, at: now, reason: "mailboxDuplicate"); return false
    }
    guard stored + entries.count < 100 else {
      overflow += 1; reject(packet, at: now, reason: "mailboxOverflow"); return false
    }
    entries[packet.sequence] = Entry(packet: packet, callbackAt: now)
    return true
  }
  private func reject(_ packet: AudioPacket, at: Double, reason: String) {
    rejections.append(["sequence": String(packet.sequence), "callbackAt": at, "decision": reason])
    if rejections.count > 32 { rejections.removeFirst(); rejectionEvictions += 1 }
  }
  func drainRejections() -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    let result = rejections; rejections = []; return result
  }
  func drain() -> [Entry] {
    lock.lock(); defer { lock.unlock() }
    let batch = entries.values.sorted { $0.callbackAt < $1.callbackAt }
    // Reserve the batch until the scheduler accounts for admitted/rejected packets.
    stored += entries.count
    entries.removeAll(keepingCapacity: true)
    return batch
  }
  /// Atomically close admission and hand pending packets back to the scheduler.
  /// Route/interruption recovery can retain them instead of silently dropping the mailbox.
  func suspend() -> [Entry] {
    lock.lock(); defer { lock.unlock() }
    generation = 0
    let batch = entries.values.sorted { $0.callbackAt < $1.callbackAt }
    stored += entries.count
    entries.removeAll(keepingCapacity: true)
    return batch
  }
  func account(stored: Int) {
    lock.lock(); self.stored = stored; lock.unlock()
  }
  var json: [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["pendingPackets": entries.count, "overflow": overflow, "duplicates": duplicates, "rejectionEvidenceEvictions": rejectionEvictions]
  }
}

enum SchedulingPolicy {
  static let target = 0.250
  static let cap = 0.300
  static let guardSeconds = 0.020
  static let passBudget = 0.005
  static let maxFramesPerPass = 6
  enum Action: Equatable { case wait, packet, conceal, exhausted }

  static func action(headroom: Double?, packetAvailable: Bool, consecutiveLosses: Int,
    atEnd: Bool) -> Action {
    guard !atEnd else { return .wait }
    guard let headroom = headroom, headroom.isFinite else { return .wait }
    guard headroom < target, headroom + 0.020 <= cap else { return .wait }
    if consecutiveLosses >= PlaybackPolicy.maximumConcealedFrames { return .exhausted }
    if packetAvailable { return .packet }
    return headroom <= guardSeconds ? .conceal : .wait
  }

  /// Headroom is in render time, projected from the last paired player timestamp.
  /// During startup, no samples have been consumed before the scheduled host start.
  static func headroom(scheduled: Int, timing: PlaybackTiming?, now: Double,
    start: Double, rate: Double, outputSlope: Double) -> Double? {
    let consumptionRate = rate * outputSlope
    guard now.isFinite, consumptionRate.isFinite, consumptionRate > 0 else { return nil }
    if now < start { return Double(scheduled) / 48000 / consumptionRate + start - now }
    guard let timing = timing, timing.valid, let host = timing.nodeHost,
      let actual = timing.actual, now - host <= 0.100, host - now <= 0.100 else { return nil }
    let consumed = actual + (now - host) * consumptionRate
    return (Double(scheduled) / 48000 - consumed) / consumptionRate
  }
}

struct OutputClockPoint {
  let epoch: UInt64
  let captured: Double
  let host: Double
  let samples: Int64
  let sampleRate: Double
  let playerSamples: Int64?
  let rateScalar: Double?
  var valid: Bool {
    captured.isFinite && host.isFinite && sampleRate.isFinite && sampleRate > 0
      && abs(captured - host) <= 0.100
  }
  var json: [String: Any] {
    ["epoch": String(epoch), "captured": captured, "host": host, "samples": samples,
     "sampleRate": sampleRate, "playerSamples": playerSamples as Any? ?? NSNull(),
     "rateScalar": rateScalar.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } as Any? ?? NSNull()]
  }
}

/// Timing confidence controls correction only. It has no authority to stop playback.
struct PlaybackTimingController {
  enum State: String { case starting, stable, outputTransition, timingUnavailable }
  struct Decision { let stateChanged: Bool; let correctionAllowed: Bool; let episodeEvent: String? }
  private(set) var state: State = .starting
  private(set) var slope: Double = 1
  private var epoch: UInt64 = 0
  private var window: OutputClockPoint?
  private var previous: OutputClockPoint?
  private var stableSince: Double?
  private var episodeSince: Double?
  private var degraded = false
  private var episode = [String: Any]()
  private var completedEpisode = [String: Any]()
  private var minimumSlope = Double.infinity
  private var maximumSlope = -Double.infinity
  private var minimumPhase = Double.infinity
  private var maximumPhase = -Double.infinity
  private var transitionSince: Double?
  private var transition = [String: Any]()
  private var transitionMinSlope = Double.infinity
  private var transitionMaxSlope = -Double.infinity
  private var transitionMinPhase = Double.infinity
  private var transitionMaxPhase = -Double.infinity
  private var goodPhaseSince: Double?
  private(set) var summary = [String: Any]()

  mutating func restart(epoch: UInt64) {
    self.epoch = epoch
    if episodeSince != nil { episode["playbackContinued"] = false }
    if transitionSince != nil { transition["playbackContinued"] = false }
    window = nil; previous = nil; stableSince = nil; goodPhaseSince = nil
    slope = 1
    state = .starting
  }
  mutating func observe(_ point: OutputClockPoint?, error: Double?, latencyFresh: Bool,
    at now: Double, timingActive: Bool = true, clockOffset: Double = 0) -> Decision {
    let old = state
    var episodeEvent: String?
    var valid = false
    if let p = point, p.valid, p.epoch == epoch {
      valid = true
      let discontinuity = previous.map {
        p.host < $0.host || p.samples < $0.samples || p.sampleRate != $0.sampleRate
          || (p.host == $0.host && p.samples != $0.samples)
          || (p.playerSamples != nil && $0.playerSamples != nil && p.playerSamples! < $0.playerSamples!)
      } ?? false
      let gap = previous.map { p.captured - $0.captured > 0.250 } ?? false
      if discontinuity {
        enterTransition(at: now)
        summary = ["reason": "timestamp discontinuity", "end": p.json,
          "start": previous?.json ?? [:]]
        window = p
      } else if gap {
        state = .timingUnavailable; stableSince = nil; window = p
      } else if let first = window, p.host - first.host >= 0.200 - 0.000001 {
        let measured = (Double(p.samples) - Double(first.samples)) / first.sampleRate / (p.host - first.host)
        if measured.isFinite && measured > 0 {
          slope = measured
          summary = ["start": first.json, "end": p.json, "outputSlope": measured]
          if abs(measured - 1) > 0.02 { enterTransition(at: now) }
          if abs(measured - 1) <= 0.005 {
            if stableSince == nil { stableSince = first.captured }
            if now - stableSince! >= 0.500 { state = .stable }
          } else { stableSince = nil }
        } else { enterTransition(at: now) }
        window = p
      }
      if window == nil { window = p }
      previous = p
    } else {
      state = .timingUnavailable; stableSince = nil
      window = nil; previous = nil
    }
    if !latencyFresh || error == nil || error?.isFinite != true {
      if state != .outputTransition { state = .timingUnavailable }
      goodPhaseSince = nil
    }
    if timingActive && latencyFresh && (!valid || error?.isFinite != true), episodeSince == nil {
      episodeSince = now
    }
    let phaseHealthy = error.map { $0.isFinite && abs($0) <= 0.050 } == true
    let healthy = valid && latencyFresh && state == .stable && phaseHealthy
    if timingActive && !healthy && episode.isEmpty {
      if episodeSince == nil { episodeSince = now }
      episode = ["entry": point?.json ?? [:], "entryClockOffsetMs": clockOffset * 1000, "playbackContinued": true, "entryPhaseErrorMs": error.flatMap { $0.isFinite ? $0 * 1000 : nil } as Any? ?? NSNull()]
      minimumSlope = .infinity; maximumSlope = -.infinity
      minimumPhase = .infinity; maximumPhase = -.infinity
    }
    if episodeSince != nil {
      if valid { minimumSlope = min(minimumSlope, slope); maximumSlope = max(maximumSlope, slope) }
      if let error = error, error.isFinite {
        minimumPhase = min(minimumPhase, error * 1000); maximumPhase = max(maximumPhase, error * 1000)
      }
      episode["exit"] = point?.json ?? [:]
      episode["timestampValid"] = valid
      episode["minimumSlope"] = minimumSlope.isFinite ? minimumSlope as Any : NSNull()
      episode["maximumSlope"] = maximumSlope.isFinite ? maximumSlope as Any : NSNull()
      episode["minimumPhaseMs"] = minimumPhase.isFinite ? minimumPhase as Any : NSNull()
      episode["maximumPhaseMs"] = maximumPhase.isFinite ? maximumPhase as Any : NSNull()
      episode["clockOffsetChangeMs"] = clockOffset * 1000 - (episode["entryClockOffsetMs"] as? Double ?? 0)
    }
    if healthy {
      if goodPhaseSince == nil { goodPhaseSince = now }
      if now - goodPhaseSince! >= 0.500, let since = episodeSince {
        episode["durationSeconds"] = now - since
        episodeEvent = "timingEpisodeEnded"
        completedEpisode = episode; episode = [:]
        episodeSince = nil; degraded = false
      }
    } else { goodPhaseSince = nil }
    if let since = episodeSince, now - since >= 3, !degraded {
      degraded = true; episodeEvent = "timingDegraded"
    }
    if let since = transitionSince {
      if transition["entryClockOffsetMs"] == nil { transition["entryClockOffsetMs"] = clockOffset * 1000 }
      if valid { transitionMinSlope = min(transitionMinSlope, slope); transitionMaxSlope = max(transitionMaxSlope, slope) }
      if let error = error, error.isFinite {
        transitionMinPhase = min(transitionMinPhase, error * 1000)
        transitionMaxPhase = max(transitionMaxPhase, error * 1000)
      }
      transition["exit"] = point?.json ?? [:]
      transition["durationSeconds"] = now - since
      transition["minimumSlope"] = transitionMinSlope.isFinite ? transitionMinSlope as Any : NSNull()
      transition["maximumSlope"] = transitionMaxSlope.isFinite ? transitionMaxSlope as Any : NSNull()
      transition["minimumPhaseMs"] = transitionMinPhase.isFinite ? transitionMinPhase as Any : NSNull()
      transition["maximumPhaseMs"] = transitionMaxPhase.isFinite ? transitionMaxPhase as Any : NSNull()
      transition["clockOffsetChangeMs"] = clockOffset * 1000 - (transition["entryClockOffsetMs"] as? Double ?? 0)
      transition["timestampValid"] = valid
      if state == .stable { transitionSince = nil; transition["completed"] = true }
    }
    summary["outputTransition"] = transition
    summary["state"] = state.rawValue
    summary["timingRecoveryPolicy"] = "observeWithoutRejoin"
    summary["degraded"] = degraded
    summary["episodeStarted"] = episodeSince as Any? ?? NSNull()
    summary["episode"] = episode.isEmpty ? completedEpisode : episode
    summary["phaseErrorMs"] = error.flatMap { $0.isFinite ? $0 * 1000 : nil } as Any? ?? NSNull()
    return Decision(stateChanged: old != state,
      correctionAllowed: healthy && goodPhaseSince.map { now - $0 >= 0.500 } == true,
      episodeEvent: episodeEvent)
  }

  private mutating func enterTransition(at now: Double) {
    if transitionSince == nil {
      transitionSince = now
      transition = ["entry": window?.json ?? previous?.json ?? [:], "playbackContinued": true, "completed": false]
      transitionMinSlope = .infinity; transitionMaxSlope = -.infinity
      transitionMinPhase = .infinity; transitionMaxPhase = -.infinity
    }
    if episodeSince == nil { episodeSince = now }
    state = .outputTransition; stableSince = nil; goodPhaseSince = nil
  }
}
