import Foundation
import Network
import XCTest
@testable import AudioCore

final class ForegroundRecoveryTests: XCTestCase {
  final class Clock {
    private let lock = NSLock()
    private var value = 0.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
  }
  func snapshot(_ session: AudioSession) -> [String: Any] {
    let done = expectation(description: "session command queue drained")
    var result = [String: Any]()
    session.inspectSnapshot { value in result = value; done.fulfill() }
    wait(for: [done], timeout: 2)
    return result
  }
  func testFreshConnectionIsRetainedAndStaleConnectionIsReplaced() {
    let clock = Clock()
    var starts = [NWConnection]()
    let session = AudioSession(isHost: false, startListener: { _, _ in },
      startConnection: { connection, _ in starts.append(connection) },
      browsingEnabled: false, now: { clock.read() }, runPeriodicTicks: false)
    session.perform("connect", args: ["host": "127.0.0.1", "port": 12345])
    session.perform("listen")
    XCTAssertTrue(snapshot(session)["listening"] as? Bool == true)
    XCTAssertEqual(starts.count, 1)
    let original = starts[0]
    clock.set(5)
    session.perform("foreground")
    _ = snapshot(session)
    XCTAssertEqual(starts.count, 1)
    clock.set(5.01)
    session.perform("foreground")
    let value = snapshot(session)
    XCTAssertEqual(starts.count, 2)
    XCTAssertFalse(starts[1] === original)
    XCTAssertEqual(starts[1].endpoint, original.endpoint)
    XCTAssertEqual(value["status"] as? String, "connecting")
    XCTAssertTrue(value["listening"] as? Bool == true)
    XCTAssertFalse(value["rendering"] as? Bool == true)
    XCTAssertFalse((value["stats"] as? [String: Any])?["clockReady"] as? Bool == true)
    session.perform("deactivate")
    _ = snapshot(session)
  }
  func testExplicitStopAndDisconnectOverrideAutomaticListening() {
    let clock = Clock()
    var starts = 0
    let session = AudioSession(isHost: false, startListener: { _, _ in },
      startConnection: { _, _ in starts += 1 }, browsingEnabled: false,
      now: { clock.read() }, runPeriodicTicks: false)
    session.perform("connect", args: ["host": "127.0.0.1", "port": 12345])
    session.perform("listen")
    session.perform("stopListening")
    _ = snapshot(session)
    clock.set(6)
    session.perform("foreground")
    XCTAssertFalse(snapshot(session)["listening"] as? Bool == true)
    XCTAssertEqual(starts, 2)
    session.perform("disconnect")
    _ = snapshot(session)
    clock.set(12)
    session.perform("foreground")
    let value = snapshot(session)
    XCTAssertEqual(starts, 2)
    XCTAssertEqual(value["status"] as? String, "disconnected")
    XCTAssertFalse(value["listening"] as? Bool == true)
    session.perform("deactivate")
    _ = snapshot(session)
  }
}
