import AVFoundation
import Foundation
import os

/// A value, never a lazy framework getter. Epoch changes invalidate all previous values.
struct LatencySnapshot {
  let epoch: UInt64
  let started: Double
  let captured: Double
  let value: PlaybackLatency
  let diagnostics: [String: Any]
  func age(at now: Double) -> Double { max(0, now - started) }
  func json(at now: Double) -> [String: Any] {
    var result = value.json
    result["epoch"] = String(epoch)
    result["startedMonotonicSeconds"] = started
    result["capturedMonotonicSeconds"] = captured
    result["ageMs"] = age(at: now) * 1000
    result["valid"] = value.valid
    result["stale"] = age(at: now) > 3
    result["getters"] = diagnostics
    return result
  }
}

struct LatencySnapshotStore {
  private(set) var epoch: UInt64 = 0
  private(set) var snapshot: LatencySnapshot?
  mutating func begin(_ epoch: UInt64) { self.epoch = epoch; snapshot = nil }
  @discardableResult mutating func accept(_ value: LatencySnapshot) -> Bool {
    guard value.epoch == epoch, value.value.valid,
      value.started.isFinite, value.captured.isFinite, value.captured >= value.started,
      snapshot.map({ value.started >= $0.started }) ?? true else { return false }
    snapshot = value
    return true
  }
}

/// Graph lifecycle and all latency reads share this queue. It never waits for the scheduler.
/// The short lock protects only request coalescing, not framework calls or rendering.
final class AudioControlQueue {
  let queue = DispatchQueue(label: "dev.silentdisco.audio.control", qos: .userInitiated)
  private let lock = NSLock()
  private var refreshing = false
  @discardableResult func refresh(read: @escaping () -> LatencySnapshot,
    deliver: @escaping (LatencySnapshot) -> Void) -> Bool {
    lock.lock()
    guard !refreshing else { lock.unlock(); return false }
    refreshing = true
    lock.unlock()
    queue.async {
      let value = read()
      self.lock.lock(); self.refreshing = false; self.lock.unlock()
      deliver(value)
    }
    return true
  }
}

/// The control queue creates/stops graphs only after the scheduler relinquishes its lease.
final class PlaybackGraph {
  let epoch: UInt64
  let engine = AVAudioEngine()
  let player = AVAudioPlayerNode()
  let speed = AVAudioUnitVarispeed()
  let output: AVAudioOutputNode
  let mixer: AVAudioMixerNode
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var getterStats = SenderDiagnostics()
  private var slowReads = [[String: Any]]()
  private static let log = OSLog(subsystem: "dev.silentdisco.audio", category: "Latency")

  init(epoch: UInt64) throws {
    self.epoch = epoch
    output = engine.outputNode
    mixer = engine.mainMixerNode
    engine.attach(player); engine.attach(speed)
    engine.connect(player, to: speed, format: format)
    engine.connect(speed, to: mixer, format: format)
    engine.prepare()
    try engine.start()
  }
  // Called exclusively on the control queue, including the opt-in high-cadence probe.
  func latency(site: String) -> LatencySnapshot {
    let began = AudioWire.now()
    #if os(iOS)
      let session = getter("sessionLookup", site: site) { AVAudioSession.sharedInstance() }
      let io: Double? = getter("ioBufferDuration", site: site) { session.ioBufferDuration }
    #else
      let io: Double? = nil
    #endif
    let node = getter("outputNodeLookup", site: site) { engine.outputNode }
    let hardware = getter("presentationLatency", site: site) { node.presentationLatency }
    let pipeline = getter("outputPresentationLatency", site: site) { player.outputPresentationLatency }
    return LatencySnapshot(epoch: epoch, started: began, captured: AudioWire.now(),
      value: PlaybackLatency(hardware: hardware, pipeline: pipeline, ioBuffer: io),
      diagnostics: ["aggregate": getterStats.json, "recentSlowReads": slowReads])
  }
  private func getter<T>(_ name: String, site: String, _ work: () -> T) -> T {
    let id = OSSignpostID(log: Self.log)
    os_signpost(.begin, log: Self.log, name: "Latency getter", signpostID: id,
      "%{public}@ site=%{public}@ epoch=%{public}llu", name as NSString, site as NSString, epoch)
    let start = AudioWire.now()
    let value = work()
    let duration = AudioWire.now() - start
    os_signpost(.end, log: Self.log, name: "Latency getter", signpostID: id)
    getterStats.record(name, seconds: duration)
    if duration >= 0.020 {
      slowReads.append(["getter": name, "site": site, "epoch": String(epoch),
        "startedMonotonicSeconds": start, "durationMs": duration * 1000])
      if slowReads.count > 4 { slowReads.removeFirst() }
    }
    return value
  }
  func stop() { player.stop(); engine.stop() }
}
