import XCTest
@testable import AudioCore

final class AudioSessionErrorsTests: XCTestCase {
  func testEstablishedConnectionMakesDiscoveryFailureIrrelevantUntilDisconnected() {
    var errors = AudioSessionErrors()
    errors.set(.discovery, "Discovery unavailable")
    XCTAssertEqual(errors.visible(connected: false), "Discovery unavailable")
    XCTAssertEqual(errors.visible(connected: true), "")
    XCTAssertEqual(errors.visible(connected: false), "Discovery unavailable")
    errors.clear(.discovery) // A fresh browser-ready/result observation confirms recovery.
    XCTAssertEqual(errors.visible(connected: false), "")
  }
  func testRecoveryClearsOnlyItsSubsystemAndKeepsManualHostWarning() {
    var errors = AudioSessionErrors()
    errors.set(.connection, "Waiting")
    errors.set(.audioSession, "Activation failed")
    errors.clear(.connection)
    XCTAssertEqual(errors.visible(connected: true), "Activation failed")
    errors.clear(.audioSession)
    errors.set(.hostDiscovery, "Manual host only")
    errors.set(.hostTransport, "Waiting for TCP")
    errors.clear(.hostTransport)
    XCTAssertEqual(errors.visible(connected: true), "Manual host only")
    errors.clear(.hostDiscovery)
    XCTAssertEqual(errors.visible(connected: false), "")
  }
  func testCommandAndDiscoveryErrorsAreNotRendererFailures() {
    var errors = AudioSessionErrors()
    errors.set(.command, "Invalid address")
    errors.set(.discovery, "Browser failed")
    XCTAssertEqual(errors.renderingError, "")
    errors.set(.renderer, "Decoder failed")
    XCTAssertEqual(errors.renderingError, "Decoder failed")
    errors.clear(.renderer)
    XCTAssertEqual(errors.visible(connected: true), "Invalid address")
  }
  func testLatePlayingStatisticsCannotHideAStoppedRendererFailure() {
    var errors = AudioSessionErrors()
    errors.set(.renderer, "Decoder failed")
    errors.rendererStats(state: "playing", listening: false, running: false)
    XCTAssertEqual(errors.renderingError, "Decoder failed")
    errors.rendererStats(state: "playing", listening: true, running: false)
    XCTAssertEqual(errors.renderingError, "Decoder failed")
    errors.rendererStats(state: "playing", listening: true, running: true)
    XCTAssertEqual(errors.renderingError, "")
  }

}
