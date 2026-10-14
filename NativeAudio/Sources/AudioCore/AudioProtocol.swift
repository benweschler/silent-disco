import AVFoundation
import Foundation

public enum AudioWire {
  public static let service = "_sdaudio._tcp"
  public static let version = 1
  public static let rate = 48_000
  public static let frames = 960
  public static let interval = 0.020
  public static let maxDuration = 600.0
  public static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

public struct AudioFailure: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct AudioPacket {
  public var kind: UInt8  // 0 register, 1 acknowledged, 2 media
  public var token: Data
  public var generation: UInt64
  public var sequence: UInt64
  public var sample: UInt64  // encoder input position; subtract negotiated lookahead for source position
  public var presentation: Double  // Mac monotonic seconds, first decoded sample
  public var payload: Data
  public init(
    kind: UInt8 = 2, token: Data, generation: UInt64 = 0, sequence: UInt64 = 0,
    sample: UInt64 = 0, presentation: Double = 0, payload: Data = Data()
  ) {
    self.kind = kind
    self.token = token
    self.generation = generation
    self.sequence = sequence
    self.sample = sample
    self.presentation = presentation
    self.payload = payload
  }
  public func encode() -> Data {
    var d = Data([83, 68, 65, 49, 1, kind, 0, 0])
    d.append(token)
    for n in [generation, sequence, sample, presentation.bitPattern] {
      var b = n.bigEndian
      withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
    }
    var n = UInt16(payload.count).bigEndian
    withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
    d.append(payload)
    return d
  }
  public init?(_ d: Data) {
    guard d.count >= 58, d.count < 1200, Array(d.prefix(5)) == [83, 68, 65, 49, 1],
      d[5] <= 2, d[6] == 0, d[7] == 0
    else { return nil }
    func u64(_ start: Int) -> UInt64 { d[start..<start + 8].reduce(0) { ($0 << 8) | UInt64($1) } }
    let n = Int(d[56]) * 256 + Int(d[57])
    guard n == d.count - 58 else { return nil }
    kind = d[5]
    token = d.subdata(in: 8..<24)
    generation = u64(24)
    sequence = u64(32)
    sample = u64(40)
    presentation = Double(bitPattern: u64(48))
    payload = d.subdata(in: 58..<d.count)
    guard presentation.isFinite, presentation >= 0 else { return nil }
    if kind == 2 {
      guard generation != 0, sequence < 30_000, sample == sequence * 960, n > 0 else { return nil }
    } else if generation != 0 || sequence != 0 || sample != 0 || presentation != 0 || n != 0 {
      return nil
    }
  }
}

public struct AudioFramer {
  private var bytes = Data()
  public init() {}
  public mutating func append(_ data: Data) throws -> [[String: Any]] {
    bytes.append(data)
    var messages = [[String: Any]]()
    while let end = bytes.firstIndex(of: 10) {
      guard end <= 16_384 else { throw AudioFailure("Control frame too large") }
      let line = Data(bytes.prefix(end))
      bytes.removeSubrange(...end)
      guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
        object["type"] is String
      else {
        throw AudioFailure("Invalid control message")
      }
      messages.append(object)
    }
    guard bytes.count <= 16_384 else { throw AudioFailure("Control frame too large") }
    return messages
  }
}

public struct ClockEstimate {
  private var samples = [(offset: Double, rtt: Double, at: Double)]()
  public private(set) var offset = 0.0  // host - phone
  public private(set) var rtt = 0.0
  public var ready: Bool { samples.count >= 4 }
  public var count: Int { samples.count }
  public init() {}
  @discardableResult public mutating func add(t1: Double, t2: Double, t3: Double, t4: Double)
    -> Bool
  {
    let delay = (t4 - t1) - (t3 - t2)
    guard [t1, t2, t3, t4].allSatisfy({ $0.isFinite }), t4 >= t1, t3 >= t2, delay >= 0,
      delay < 0.250
    else { return false }
    samples.removeAll { t4 - $0.at > 30 }
    let candidate = (t2 - t1) / 2 + (t3 - t4) / 2
    guard candidate.isFinite else { return false }
    samples.append((candidate, delay, t4))
    if samples.count > 32 { samples.removeFirst() }
    let best = samples.sorted { $0.rtt < $1.rtt }.prefix(5)
    let offsets = best.map(\.offset).sorted()
    offset = offsets[offsets.count / 2]
    rtt = best.first!.rtt
    return true
  }
}

public struct GapStats {
  public private(set) var maximum = 0.0
  public private(set) var lastGap = 0.0
  public private(set) var counts = [0, 0, 0, 0]
  public private(set) var durations = [Double](repeating: 0, count: 4)
  private var previous: Double?
  public init() {}
  public mutating func arrival(_ now: Double) {
    defer { previous = now }
    guard let last = previous else { return }
    let gap = max(0, now - last)
    lastGap = gap
    maximum = max(maximum, gap)
    for (i, limit) in [0.1, 0.25, 0.5, 1.0].enumerated() where gap > limit {
      counts[i] += 1
      durations[i] += gap
    }
  }
  public var json: [String: Any] {
    [
      "maxMs": maximum * 1000, "thresholdsMs": [100, 250, 500, 1000], "counts": counts,
      "totalDurationsMs": durations.map { $0 * 1000 },
    ]
  }
}

// Render queue owns this bounded buffer. Missing sequence numbers become loss only at their deadline.
public struct AudioJitterBuffer {
  public private(set) var packets = [UInt64: AudioPacket]()
  public private(set) var duplicates = 0
  public private(set) var rejected = 0
  public private(set) var late = 0
  public private(set) var expected: UInt64?
  public let capacity = 100
  public private(set) var lateAfterConcealment = 0
  public private(set) var maximumReorderDepth = 0
  private var highestSequence: UInt64?
  private var concealedSequences = Set<UInt64>()
  private var committedThrough: UInt64?
  public init() {}
  public mutating func insert(_ p: AudioPacket, hostNow: Double, outputLead: Double,
    enforcePresentationDeadline: Bool = true) {
    if concealedSequences.remove(p.sequence) != nil { lateAfterConcealment += 1 }
    if let highest = highestSequence, p.sequence < highest {
      maximumReorderDepth = max(maximumReorderDepth, Int(min(30000, highest - p.sequence)))
    }
    highestSequence = max(highestSequence ?? p.sequence, p.sequence)
    if let committed = committedThrough, p.sequence <= committed {
      late += 1
      return
    }
    guard !enforcePresentationDeadline || p.presentation > hostNow + outputLead else {
      late += 1
      return
    }
    if let expected = expected, p.sequence < expected {
      late += 1
      return
    }
    if packets[p.sequence] != nil {
      duplicates += 1
      return
    }
    guard p.presentation - hostNow <= 2, packets.count < capacity else {
      rejected += 1
      return
    }
    packets[p.sequence] = p
  }
  public mutating func begin(at sequence: UInt64) {
    expected = sequence
    packets = packets.filter { $0.key >= sequence }
  }
  public mutating func take() -> AudioPacket? {
    guard let n = expected else { return nil }
    expected = n + 1
    committedThrough = max(committedThrough ?? n, n)
    return packets.removeValue(forKey: n)
  }
  public var nextPacket: AudioPacket? { expected.flatMap { packets[$0] } }
  public var contiguousPackets: Int {
    guard var n = expected ?? first?.sequence else { return 0 }
    var count = 0
    while packets[n] != nil && count < capacity { count += 1; n += 1 }
    return count
  }
  public mutating func markConcealed(_ sequence: UInt64) {
    concealedSequences.insert(sequence)
    if concealedSequences.count > 100, let first = concealedSequences.min() {
      concealedSequences.remove(first)
    }
  }
  /// A local playback restart leaves future encoded packets available for rejoining.
  public mutating func rejoin() { expected = nil }
  public mutating func discard(before hostTime: Double) {
    let previousCount = packets.count
    packets = packets.filter { $0.value.presentation > hostTime }
    late += previousCount - packets.count
  }
  public mutating func reset() {
    packets.removeAll(keepingCapacity: true)
    expected = nil
  }
  public var first: AudioPacket? { packets.values.min { $0.sequence < $1.sequence } }
}

public enum PlaybackPolicy {
  public static func rate(error: Double) -> Float {
    Float(1 + min(0.001, max(-0.001, error * 0.02)))
  }
  public static func mustResync(error: Double) -> Bool { abs(error) > 0.050 }
  public static let maximumConcealedFrames = 6
}

/// A delayed tick emits only the current frame, never a burst of expired frames.
public struct AudioPacer {
  public private(set) var next: UInt64 = 0
  public private(set) var skipped = 0
  public init() {}
  public mutating func take(elapsed: Double) -> UInt64? {
    guard elapsed.isFinite, elapsed >= 0, elapsed < AudioWire.maxDuration else { return nil }
    let slot = UInt64(floor(elapsed / AudioWire.interval))
    guard slot >= next else { return nil }
    skipped += Int(slot - next)
    next = slot + 1
    return slot
  }
}
