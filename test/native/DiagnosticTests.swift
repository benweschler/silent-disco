import XCTest

@testable import DiagnosticsCore

final class DiagnosticTests: XCTestCase {
  func testPacketFixtureAndValidation() throws {
    let token = Data(0..<16)
    let packet = DiagnosticPacket(
      kind: 2, stream: 1, token: token, run: 0x0102_0304_0506_0708,
      sequence: 42, timestamp: 1_000_000_000)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("fixtures/packet-v1.hex")
    let expected = try String(contentsOf: fixture).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(packet.encode().map { String(format: "%02x", $0) }.joined(), expected)
    let decoded = try XCTUnwrap(DiagnosticPacket(packet.encode()))
    XCTAssertEqual(decoded.run, packet.run)
    XCTAssertEqual(decoded.sequence, 42)
    XCTAssertEqual(decoded.timestamp, 1_000_000_000)
    XCTAssertEqual(decoded.token, token)
    for index in [0, 4, 5, 399] {
      var invalid = packet.encode()
      invalid[index] = 0xff
      XCTAssertNil(DiagnosticPacket(invalid))
    }
    XCTAssertNil(DiagnosticPacket(packet.encode().dropLast()))
  }
  func testFramingAcrossReadsAndCoalescedMessages() throws {
    var framer = ControlFramer()
    XCTAssertTrue(try framer.append(Data("{\"ty".utf8)).isEmpty)
    let messages = try framer.append(Data("pe\":\"hello\"}\n{\"type\":\"heartbeat\"}\n".utf8))
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0]["type"] as? String, "hello")
    XCTAssertTrue(try framer.append(Data()).isEmpty)
    XCTAssertThrowsError(try framer.append(Data("{invalid}\n".utf8)))
    var oversized = ControlFramer()
    XCTAssertThrowsError(
      try oversized.append(Data(repeating: 65, count: DiagnosticProtocol.maxFrame + 1)))
    var oversizedLine = ControlFramer()
    XCTAssertThrowsError(
      try oversizedLine.append(
        Data(repeating: 65, count: DiagnosticProtocol.maxFrame + 1) + Data([10])))
  }
  func testUniqueCountersAndReordering() {
    var counter = PacketCounter()
    XCTAssertTrue(counter.record(sequence: 0, stream: 0, at: 1, interval: 0.02))
    XCTAssertTrue(counter.record(sequence: 2, stream: 0, at: 1.04, interval: 0.02))
    XCTAssertFalse(counter.record(sequence: 2, stream: 0, at: 1.05, interval: 0.02))
    XCTAssertTrue(counter.record(sequence: 1, stream: 0, at: 1.06, interval: 0.02))
    XCTAssertEqual(counter.unique, 3)
    XCTAssertEqual(counter.duplicates, 1)
    XCTAssertEqual(counter.reordered, 1)
    XCTAssertEqual(counter.maxGapMs, 40, accuracy: 0.0001)
    XCTAssertEqual(counter.snapshot(elapsed: 1)["payloadKbps"] as? Double, 9.6)
  }
  func testPacerSkipsMissedSlotsWithoutBurst() {
    var pacer = PacketPacer(nextDeadline: 1, interval: 0.02)
    XCTAssertFalse(pacer.due(at: 0.9).send)
    XCTAssertTrue(pacer.due(at: 1).send)
    let late = pacer.due(at: 1.091)
    XCTAssertTrue(late.send)
    XCTAssertEqual(late.skipped, 3)
    XCTAssertFalse(pacer.due(at: 1.091).send)
    XCTAssertEqual(pacer.nextDeadline, 1.1, accuracy: 0.0001)
  }
  func testProfilesHaveHardTenMinuteMaximumAndRetryCaps() {
    XCTAssertEqual(TestProfile.connectivity.duration, 30)
    XCTAssertEqual(TestProfile.baseline.duration, 600)
    XCTAssertEqual(TestProfile.threeChannel.streams, 3)
    XCTAssertNil(TestProfile(rawValue: "unlimited"))
    XCTAssertTrue(TestProfile.allCases.allSatisfy { $0.duration <= 600 })
    var retry = RetrySchedule()
    XCTAssertEqual((0..<6).map { _ in retry.next() }, [1, 2, 4, 5, 5, 5])
    retry.reset()
    XCTAssertEqual(retry.next(), 1)
  }

  func testDeadlinesWithFakeTime() {
    XCTAssertFalse(
      ConnectionDeadline.expired(now: 104.9, lastHeard: 100, connectedAt: 100, ready: true))
    XCTAssertTrue(
      ConnectionDeadline.expired(now: 105, lastHeard: 100, connectedAt: 100, ready: true))
    XCTAssertTrue(
      ConnectionDeadline.expired(now: 110, lastHeard: 109, connectedAt: 100, ready: false))
    XCTAssertFalse(
      ConnectionDeadline.expired(now: 110, lastHeard: 109, connectedAt: 100, ready: true))
    XCTAssertFalse(TestProfile.baseline.expired(since: 100, at: 699.999))
    XCTAssertTrue(TestProfile.baseline.expired(since: 100, at: 700))
    XCTAssertEqual(TestProfile.baseline.elapsed(since: 100, at: 900), 600)
    XCTAssertTrue(TestProfile.connectivity.expired(since: 100, at: 130))
  }

  func testBackgroundInterruptsAndForegroundReconnectsWithoutRestartingRun() throws {
    guard ProcessInfo.processInfo.environment["SD_NETWORK_TEST"] == "1" else {
      throw XCTSkip("Set SD_NETWORK_TEST=1 for the lifecycle socket test.")
    }
    let interrupted = expectation(description: "interrupted report")
    let reconnected = expectation(description: "foreground reconnect without run")
    let stopped = expectation(description: "host stopped")
    let host = DiagnosticEngine(isHost: true)
    let phone = DiagnosticEngine(isHost: false)
    var attached = false
    var started = false
    var didInterrupt = false
    var sawReconnect = false
    host.onSnapshot = { snapshot in
      if !attached, let port = snapshot["tcpPort"] as? Int, port > 0,
        snapshot["status"] as? String == "listening"
      {
        attached = true
        phone.perform("connect", args: ["host": "127.0.0.1", "port": port])
      }
      if !started, snapshot["ready"] as? Bool == true {
        started = true
        host.perform("startTest", args: ["profile": "baseline"])
      }
      if didInterrupt, !sawReconnect, snapshot["ready"] as? Bool == true {
        sawReconnect = true
        XCTAssertEqual(snapshot["active"] as? Bool, false)
        reconnected.fulfill()
        phone.perform("disconnect")
        host.perform("stopHost")
      }
      if sawReconnect, snapshot["hosting"] as? Bool == false {
        stopped.fulfill()
        host.onSnapshot = nil
      }
    }
    var sentBackground = false
    phone.onSnapshot = { snapshot in
      if !sentBackground, snapshot["phase"] as? String == "running" {
        sentBackground = true
        phone.queue.asyncAfter(deadline: .now() + 0.3) { phone.perform("background") }
      }
    }
    host.onReport = { report in
      guard !didInterrupt else { return }
      XCTAssertEqual(report["status"] as? String, "interrupted")
      XCTAssertEqual(report["completeCounters"] as? Bool, false)
      XCTAssertTrue(report["downstreamMissing"] is NSNull)
      interrupted.fulfill()
      // Queue foreground after the disconnect snapshot has completed.
      host.queue.asyncAfter(deadline: .now() + 0.1) {
        didInterrupt = true
        phone.perform("foreground")
      }
    }
    host.perform("startHost")
    wait(for: [interrupted, reconnected, stopped], timeout: 12)
    phone.onSnapshot = nil
    phone.perform("disconnect")
    host.perform("stopHost")
  }

  // Opt in to real local sockets, separate from deterministic unit tests.
  func testLocalhostConnectivityAndCleanup() throws {
    guard ProcessInfo.processInfo.environment["SD_NETWORK_TEST"] == "1" else {
      throw XCTSkip("Set SD_NETWORK_TEST=1 to run the 30-second local socket integration test.")
    }
    let done = expectation(description: "30-second report")
    let idle = expectation(description: "listeners cleaned up")
    let host = DiagnosticEngine(isHost: true)
    let phone = DiagnosticEngine(isHost: false)
    var connected = false
    var started = false
    var reported = false
    host.onSnapshot = { snapshot in
      if !connected, let port = snapshot["tcpPort"] as? Int, port > 0,
        snapshot["status"] as? String == "listening"
      {
        connected = true
        phone.perform("connect", args: ["host": "127.0.0.1", "port": port])
      }
      if !started, snapshot["ready"] as? Bool == true {
        started = true
        host.perform("startTest", args: ["profile": "connectivity"])
      }
      if reported, snapshot["hosting"] as? Bool == false {
        idle.fulfill()
        host.onSnapshot = nil
      }
    }
    host.onReport = { report in
      guard !reported else { return }
      reported = true
      XCTAssertEqual(report["status"] as? String, "completed")
      XCTAssertEqual(report["completeCounters"] as? Bool, true)
      let metrics = report["hostMetrics"] as? [String: Any]
      XCTAssertGreaterThan(metrics?["unique"] as? Int ?? 0, 100)
      XCTAssertEqual(report["downstreamMissing"] as? Int, 0)
      XCTAssertEqual(report["upstreamMissing"] as? Int, 0)
      done.fulfill()
      phone.perform("disconnect")
      host.perform("stopHost")
    }
    host.perform("startHost")
    wait(for: [done, idle], timeout: 45)
    phone.perform("disconnect")
    host.perform("stopHost")
  }
}
