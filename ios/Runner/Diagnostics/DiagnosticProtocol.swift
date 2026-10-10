import Foundation

// Keep this file and its fixtures identical in the host and listener repositories.
enum DiagnosticProtocol {
  static let version = 1
  static let service = "_silentdisco._tcp"
  static let maxFrame = 16_384
  static let maxDuration: Double = 600
  static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}

enum TestProfile: String, CaseIterable {
  case connectivity, baseline, threeChannel
  var duration: Double { self == .connectivity ? 30 : DiagnosticProtocol.maxDuration }
  var interval: Double { self == .connectivity ? 0.2 : 0.02 }
  var streams: Int { self == .threeChannel ? 3 : 1 }
  func elapsed(since start: Double, at now: Double) -> Double {
    min(max(0, now - start), min(duration, DiagnosticProtocol.maxDuration))
  }
  func expired(since start: Double, at now: Double) -> Bool {
    now - start >= min(duration, DiagnosticProtocol.maxDuration)
  }
}

struct DiagnosticPacket {
  // 400 bytes: magic(4), version(1), kind(1), stream(2), token(16),
  // run(8), sequence(8), monotonic nanoseconds(8), deterministic padding(352).
  var kind: UInt8  // 0 registration, 1 acknowledgement, 2 data, 3 echo
  var stream: UInt16
  var token: Data
  var run: UInt64
  var sequence: UInt64
  var timestamp: UInt64

  func encode() -> Data {
    var bytes = [UInt8](repeating: 0xa5, count: 400)
    bytes.replaceSubrange(0..<4, with: [0x53, 0x44, 0x44, 0x31])
    bytes[4] = 1
    bytes[5] = kind
    func put(_ value: UInt64, _ offset: Int, _ size: Int) {
      for i in 0..<size {
        bytes[offset + i] = UInt8(truncatingIfNeeded: value >> ((size - 1 - i) * 8))
      }
    }
    put(UInt64(stream), 6, 2)
    precondition(token.count == 16)
    bytes.replaceSubrange(8..<24, with: token)
    put(run, 24, 8)
    put(sequence, 32, 8)
    put(timestamp, 40, 8)
    return Data(bytes)
  }

  init(
    kind: UInt8, stream: UInt16 = 0, token: Data, run: UInt64 = 0,
    sequence: UInt64 = 0, timestamp: UInt64 = 0
  ) {
    self.kind = kind
    self.stream = stream
    self.token = token
    self.run = run
    self.sequence = sequence
    self.timestamp = timestamp
  }

  init?(_ data: Data) {
    let bytes = [UInt8](data)
    guard bytes.count == 400, Array(bytes[0..<4]) == [0x53, 0x44, 0x44, 0x31],
      bytes[4] == 1, bytes[5] <= 3, bytes[48...].allSatisfy({ $0 == 0xa5 })
    else { return nil }
    func get(_ offset: Int, _ size: Int) -> UInt64 {
      bytes[offset..<(offset + size)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    kind = bytes[5]
    stream = UInt16(get(6, 2))
    token = Data(bytes[8..<24])
    run = get(24, 8)
    sequence = get(32, 8)
    timestamp = get(40, 8)
  }
}

struct ControlFramer {
  private var pending = Data()
  mutating func append(_ data: Data) throws -> [[String: Any]] {
    pending.append(data)
    var messages = [[String: Any]]()
    while let newline = pending.firstIndex(of: 10) {
      guard pending.distance(from: pending.startIndex, to: newline) <= DiagnosticProtocol.maxFrame
      else {
        throw ProtocolError.invalidFrame
      }
      let frame = Data(pending[..<newline])
      pending = Data(pending[pending.index(after: newline)...])
      guard let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
        message["type"] is String
      else { throw ProtocolError.invalidFrame }
      messages.append(message)
    }
    guard pending.count <= DiagnosticProtocol.maxFrame else { throw ProtocolError.invalidFrame }
    return messages
  }
  enum ProtocolError: Error { case invalidFrame }
}

struct PacketCounter {
  private(set) var seen = Set<UInt64>()
  private(set) var duplicates = 0
  private(set) var reordered = 0
  private var highest: UInt64?
  private var lastArrival: [UInt16: Double] = [:]
  private(set) var maxGapMs: Double = 0
  private var variationSum: Double = 0
  private var intervals = 0
  var unique: Int { seen.count }
  mutating func record(sequence: UInt64, stream: UInt16, at now: Double, interval: Double) -> Bool {
    guard seen.insert(sequence).inserted else {
      duplicates += 1
      return false
    }
    if let highest = highest, sequence < highest { reordered += 1 }
    highest = max(highest ?? sequence, sequence)
    if let last = lastArrival[stream] {
      let gap = max(0, now - last)
      maxGapMs = max(maxGapMs, gap * 1000)
      variationSum += abs(gap - interval) * 1000
      intervals += 1
    }
    lastArrival[stream] = now
    return true
  }
  func snapshot(elapsed: Double) -> [String: Any] {
    [
      "unique": unique, "duplicates": duplicates, "reordered": reordered,
      "maxGapMs": maxGapMs,
      "meanInterarrivalVariationMs": intervals == 0 ? 0 : variationSum / Double(intervals),
      "payloadKbps": Double(unique * 400 * 8) / max(elapsed, 0.001) / 1000,
    ]
  }
}

struct PacketPacer {
  var nextDeadline: Double
  let interval: Double
  // At most one batch per tick; skipped slots are never sent in a burst.
  mutating func due(at now: Double) -> (send: Bool, skipped: Int) {
    guard now >= nextDeadline else { return (false, 0) }
    let skipped = max(0, Int((now - nextDeadline) / interval))
    nextDeadline += Double(skipped + 1) * interval
    return (true, skipped)
  }
}

struct RetrySchedule {
  private var attempt = 0
  mutating func next() -> Double {
    let result = [1.0, 2, 4, 5][min(attempt, 3)]
    attempt += 1
    return result
  }
  mutating func reset() { attempt = 0 }
}

struct ConnectionDeadline {
  static func expired(now: Double, lastHeard: Double, connectedAt: Double, ready: Bool) -> Bool {
    now - lastHeard >= 5 || (!ready && now - connectedAt >= 10)
  }
}
