import AVFoundation
import Network
import XCTest

@testable import AudioCore

final class AudioCoreTests: XCTestCase {
  let token = Data(repeating: 7, count: 16)
  func packet(_ sequence: UInt64, _ presentation: Double = 101) -> AudioPacket {
    AudioPacket(
      token: token, generation: 12, sequence: sequence, sample: sequence * 960,
      presentation: presentation, payload: Data([1, 2, 3]))
  }
  func testPacketRoundTripAndValidation() {
    let p = packet(42)
    let d = p.encode()
    let decoded = AudioPacket(d)!
    XCTAssertEqual(decoded.sequence, 42)
    XCTAssertEqual(decoded.sample, 40320)
    XCTAssertEqual(decoded.token, token)
    XCTAssertEqual(decoded.presentation, 101)
    XCTAssertNil(AudioPacket(d.dropLast()))
    var wrong = d
    wrong[4] = 2
    XCTAssertNil(AudioPacket(wrong))
    wrong = d
    wrong[7] = 1
    XCTAssertNil(AudioPacket(wrong))
    wrong = d
    wrong[56] = 255
    XCTAssertNil(AudioPacket(wrong))
    XCTAssertNil(AudioPacket(packet(30000).encode()))
    XCTAssertNil(
      AudioPacket(
        AudioPacket(token: token, generation: 1, presentation: .nan, payload: Data([0])).encode()))
    XCTAssertEqual(AudioPacket(AudioPacket(kind: 0, token: token).encode())?.kind, 0)
  }
  func testFramingSplitCoalescedAndBounded() throws {
    var f = AudioFramer()
    XCTAssertTrue(try f.append(Data("{\"type\":".utf8)).isEmpty)
    XCTAssertEqual(try f.append(Data("\"hello\"}\n{\"type\":\"ready\"}\n".utf8)).count, 2)
    XCTAssertThrowsError(try f.append(Data(repeating: 32, count: 16385)))
    var bad = AudioFramer()
    XCTAssertThrowsError(try bad.append(Data("[]\n".utf8)))
  }
  func testClockRejectsInvalidAndFavorsLowRTT() {
    var c = ClockEstimate()
    for i in 0..<8 {
      let t = Double(i)
      XCTAssertTrue(c.add(t1: t, t2: t + 5.002, t3: t + 5.003, t4: t + 0.005))
    }
    XCTAssertTrue(c.ready)
    XCTAssertEqual(c.offset, 5, accuracy: 0.000001)
    XCTAssertTrue(c.add(t1: 9, t2: 14.1, t3: 14.101, t4: 9.12))
    XCTAssertEqual(c.offset, 5, accuracy: 0.000001)
    XCTAssertFalse(c.add(t1: 1, t2: 2, t3: 1, t4: 2))
    XCTAssertFalse(c.add(t1: 0, t2: .nan, t3: 1, t4: 1))
  }
  func testJitterReorderDuplicatesLateAndCapacity() {
    var b = AudioJitterBuffer()
    b.insert(packet(2), hostNow: 100, outputLead: 0)
    b.insert(packet(1), hostNow: 100, outputLead: 0)
    b.insert(packet(1), hostNow: 100, outputLead: 0)
    XCTAssertEqual(b.duplicates, 1)
    XCTAssertEqual(b.first?.sequence, 1)
    b.begin(at: 1)
    XCTAssertEqual(b.take()?.sequence, 1)
    XCTAssertEqual(b.take()?.sequence, 2)
    XCTAssertNil(b.take())
    b.insert(packet(1), hostNow: 100, outputLead: 0)
    XCTAssertEqual(b.late, 1)
    for n in 4..<150 { b.insert(packet(UInt64(n)), hostNow: 100, outputLead: 0) }
    XCTAssertEqual(b.packets.count, 100)
    XCTAssertGreaterThan(b.rejected, 0)
    b.reset()
    XCTAssertNil(b.expected)
    XCTAssertTrue(b.packets.isEmpty)
    b.insert(packet(10, 100.02), hostNow: 100, outputLead: 0.03)
    XCTAssertTrue(b.packets.isEmpty)
  }
  func testOutageDiscardsOldTimelineAndDriftIsBounded() {
    var b = AudioJitterBuffer()
    b.insert(packet(1, 101), hostNow: 100, outputLead: 0)
    b.discard(before: 102)
    XCTAssertNil(b.first)
    b.insert(packet(90, 102.5), hostNow: 102, outputLead: 0)
    b.begin(at: 90)
    XCTAssertEqual(b.take()?.sequence, 90)
    XCTAssertEqual(PlaybackPolicy.rate(error: 1), 1.001, accuracy: 0.00001)
    XCTAssertEqual(PlaybackPolicy.rate(error: -1), 0.999, accuracy: 0.00001)
    XCTAssertTrue(PlaybackPolicy.mustResync(error: 0.051))
    XCTAssertFalse(PlaybackPolicy.mustResync(error: 0.01))
    XCTAssertEqual(PlaybackPolicy.maximumConcealedFrames * 20, 120)
  }
  func testGapCountsDescribeIncidents() {
    var gaps = GapStats()
    [0.0, 0.02, 0.22, 0.62, 1.82].forEach { gaps.arrival($0) }
    XCTAssertEqual(gaps.counts, [3, 2, 1, 1])
    XCTAssertEqual(gaps.maximum, 1.2, accuracy: 0.00001)
  }
  func testCodecRoundTripAndLookaheadAlignment() throws {
    let codec = try AudioCodec()
    let source = try AudioSource(kind: .tone)
    XCTAssertGreaterThan(codec.lookahead, 0)
    XCTAssertLessThan(codec.lookahead, 960)
    var original = [Float]()
    var decoded = [Float]()
    for i in 0..<12 {
      let pcm = try source.frame(at: UInt64(i) * 960)
      original += pcm
      let payload = try codec.encode(pcm)
      XCTAssertLessThan(payload.count + 58, 1200)
      decoded += try codec.decode(payload)
    }
    let shift = codec.lookahead * 2
    var total: Float = 0
    for i in 4000..<(original.count - shift) { total += abs(original[i] - decoded[i + shift]) }
    let error = total / Float(original.count - 4000 - shift)
    XCTAssertLessThan(error, 0.025)
    XCTAssertEqual(try codec.decode(nil).count, 1920)
    codec.resetDecoder()
    XCTAssertThrowsError(try codec.encode([0]))
  }
  func testFileConversionAndLoopingFrom44100Mono() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
      buffer.frameLength = 4410
      for i in 0..<4410 {
        buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.2)
      }
      try file.write(from: buffer)
    }
    let source = try AudioSource(kind: .file, url: url)
    for n in 0..<15 {
      let pcm = try source.frame(at: UInt64(n) * 960)
      XCTAssertEqual(pcm.count, 1920)
      XCTAssertTrue(pcm.allSatisfy(\.isFinite))
      XCTAssertGreaterThan(pcm.map(abs).max()!, 0.1)
    }
    XCTAssertEqual(try source.frame(at: 48000).count, 1920)
  }
  func testPacingSkipsExpiredFramesAndCapsDuration() {
    var pacer = AudioPacer()
    XCTAssertEqual(pacer.take(elapsed: 0), 0)
    XCTAssertNil(pacer.take(elapsed: 0.005))
    XCTAssertEqual(pacer.take(elapsed: 0.21), 10)
    XCTAssertEqual(pacer.skipped, 9)
    XCTAssertNil(pacer.take(elapsed: 0.211))
    XCTAssertNil(pacer.take(elapsed: 600))
    XCTAssertNil(pacer.take(elapsed: .infinity))
  }
  func testListeningLifecycleKeepsExplicitStopAuthoritative() {
    let phone = AudioSession(isHost: false)
    func check(_ command: String, _ args: [String: Any] = [:], wants: Bool) {
      let emitted = expectation(description: command)
      phone.onSnapshot = { state in
        XCTAssertEqual(state["listening"] as? Bool, wants)
        XCTAssertEqual(state["rendering"] as? Bool, false)
        emitted.fulfill()
      }
      phone.perform(command, args: args)
      wait(for: [emitted], timeout: 2)
    }
    check("listen", wants: true)
    check("interruptionBegan", wants: true)
    check("interruptionEnded", ["resume": false], wants: false)
    check("listen", wants: true)
    check("headphonesRemoved", wants: false)
    check("mediaReset", wants: false)
    check("interruptionEnded", ["resume": true], wants: false)
    check("listen", wants: true)
    check("stopListening", wants: false)
    check("deactivate", wants: false)
    phone.onSnapshot = nil
  }
  func testHostBonjourFailureFallsBackAndIgnoresStaleCallbacks() {
    let ready = expectation(description: "manual host survives stale listener failure")
    var starts = 0
    var originalTCP: NWListener?
    let host = AudioSession(
      isHost: true,
      startListener: { listener, queue in
        starts += 1
        let attempt = starts
        queue.async {
          if attempt == 2 {
            originalTCP = listener
            listener.stateUpdateHandler?(.failed(.dns(-65555)))
          } else {
            if attempt == 4 {
              XCTAssertNil(listener.service)
              originalTCP?.stateUpdateHandler?(.failed(.dns(-65555)))
            }
            listener.stateUpdateHandler?(.ready)
          }
        }
      })
    host.onSnapshot = { snapshot in
      if snapshot["status"] as? String == "hosting" {
        XCTAssertEqual(starts, 4)
        XCTAssertEqual(snapshot["hosting"] as? Bool, true)
        XCTAssertTrue(
          (snapshot["error"] as? String ?? "").contains("Bonjour discovery unavailable"))
        XCTAssertFalse((snapshot["events"] as? [[String: Any]] ?? []).isEmpty)
        ready.fulfill()
      }
    }
    host.perform("startHost")
    wait(for: [ready], timeout: 2)
    host.perform("stopHost")
  }

  func testHostTransportFailureIsVisibleWithoutRetryLoop() {
    let failed = expectation(description: "transport failure published")
    var starts = 0
    let host = AudioSession(
      isHost: true,
      startListener: { listener, queue in
        starts += 1
        let attempt = starts
        queue.async {
          if attempt == 2 { listener.stateUpdateHandler?(.failed(.posix(.EACCES))) }
        }
      })
    host.onSnapshot = { snapshot in
      if snapshot["hosting"] as? Bool == false,
        (snapshot["error"] as? String ?? "").contains("TCP listener failed")
      {
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(snapshot["status"] as? String, "idle")
        failed.fulfill()
      }
    }
    host.perform("startHost")
    wait(for: [failed], timeout: 2)
    host.perform("deactivate")
  }

  func testTwoClientsLateJoinAndFailureIsolation() throws {
    try exerciseTwoClients(forceBonjourFailure: false)
  }
  func testManualHostAfterBonjourFailureDeliversToTwoClients() throws {
    try exerciseTwoClients(forceBonjourFailure: true)
  }
  private func exerciseTwoClients(forceBonjourFailure: Bool) throws {
    guard ProcessInfo.processInfo.environment["SD_AUDIO_NETWORK_TEST"] == "1" else {
      throw XCTSkip("Set SD_AUDIO_NETWORK_TEST=1 for real sockets")
    }
    let host = AudioSession(
      isHost: true,
      startListener: { listener, queue in
        if forceBonjourFailure, listener.service != nil {
          queue.async { listener.stateUpdateHandler?(.failed(.dns(-65555))) }
        } else {
          listener.start(queue: queue)
        }
      })
    let listening = expectation(description: "host ready")
    let lock = NSLock()
    var port = 0
    var announced = false
    host.onSnapshot = { snapshot in
      lock.lock()
      defer { lock.unlock() }
      if !announced, let p = snapshot["port"] as? Int, p > 0 {
        port = p
        announced = true
        listening.fulfill()
      }
    }
    host.perform("startHost")
    wait(for: [listening], timeout: 5)
    lock.lock()
    let target = port
    lock.unlock()
    let a = TestListener(port: target)
    let b = TestListener(port: target)
    let readyA = expectation(description: "first ready")
    a.onReady = { readyA.fulfill() }
    a.start()
    wait(for: [readyA], timeout: 5)
    host.perform("startStream")
    let first = expectation(description: "first receives")
    a.onPackets = { n in if n == 10 { first.fulfill() } }
    wait(for: [first], timeout: 5)
    let second = expectation(description: "late listener receives after first leaves")
    b.onPackets = { n in
      if n == 5 { a.stop() }
      if n == 25 { second.fulfill() }
    }
    let stopped = expectation(description: "explicit final source frame")
    b.onStop = { finalSequence in
      XCTAssertNotNil(finalSequence)
      XCTAssertLessThan(finalSequence ?? 30000, 30000)
      stopped.fulfill()
    }
    b.start()
    wait(for: [second], timeout: 5)
    let report = expectation(description: "incomplete report retained")
    host.onReport = { r in
      XCTAssertEqual(r["completeCounters"] as? Bool, false)
      XCTAssertEqual(r["acousticSynchronization"] as? String, "unverified")
      XCTAssertEqual(r["userReportedAudibleInterruptions"] as? Int, 1)
      report.fulfill()
    }
    host.perform("markAudibleInterruption")
    host.perform("stopStream")
    wait(for: [report, stopped], timeout: 5)
    a.stop()
    b.stop()
    host.perform("stopHost")
  }
}

private final class TestListener {
  let queue = DispatchQueue(label: "audio.test.client")
  let tcp: NWConnection
  var udp: NWConnection?
  var framer = AudioFramer()
  var token = Data()
  var onReady: (() -> Void)?
  var onPackets: ((Int) -> Void)?
  var onStop: ((UInt64?) -> Void)?
  var packets = 0
  var acknowledged = false
  init(port: Int) {
    tcp = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
  }
  func start() {
    tcp.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        self?.send(["type": "hello", "version": 1])
        self?.read()
      }
    }
    tcp.start(queue: queue)
  }
  func send(_ m: [String: Any]) {
    var d = try! JSONSerialization.data(withJSONObject: m)
    d.append(10)
    tcp.send(content: d, completion: .contentProcessed { _ in })
  }
  func read() {
    tcp.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
      [weak self] data, _, done, error in
      guard let self = self else { return }
      if let data = data, let frames = try? self.framer.append(data) {
        for m in frames {
          if m["type"] as? String == "welcome" {
            self.token = Data(base64Encoded: m["token"] as! String)!
            let c = NWConnection(
              host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(m["udpPort"] as! Int))!,
              using: .udp)
            self.udp = c
            c.stateUpdateHandler = { [weak self] state in
              if case .ready = state, let self = self {
                c.send(
                  content: AudioPacket(kind: 0, token: self.token).encode(),
                  completion: .contentProcessed { _ in })
                self.readUDP()
              }
            }
            c.start(queue: self.queue)
          }
          if m["type"] as? String == "stop" {
            self.onStop?((m["lastSequence"] as? String).flatMap(UInt64.init))
          }
          if m["type"] as? String == "heartbeat" { self.send(["type": "heartbeat"]) }
        }
      }
      if !done && error == nil { self.read() }
    }
  }
  func readUDP() {
    udp?.receiveMessage { [weak self] data, _, _, error in
      guard let self = self, error == nil else { return }
      if let data = data, let p = AudioPacket(data), p.token == self.token {
        if p.kind == 1 && !self.acknowledged {
          self.acknowledged = true
          self.send(["type": "ready"])
          self.send(["type": "listen", "enabled": true])
          self.onReady?()
        }
        if p.kind == 2 {
          self.packets += 1
          self.onPackets?(self.packets)
        }
      }
      self.readUDP()
    }
  }
  func stop() {
    tcp.cancel()
    udp?.cancel()
  }
}
