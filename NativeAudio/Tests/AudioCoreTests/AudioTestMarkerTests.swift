import XCTest
@testable import AudioCore

final class AudioTestMarkerTests: XCTestCase {
  func testMarkerUsesCapturedTimeAndExplicitUserReportedLabel() throws {
    let value = try XCTUnwrap(AudioTestMarker.event("wakeLocked", at: 12.5, utc: "captured", origin: 10))
    XCTAssertEqual(value["kind"] as? String, "userReportedTransition")
    XCTAssertEqual(value["at"] as? String, "captured")
    XCTAssertEqual(value["streamSeconds"] as? Double, 2.5)
    XCTAssertEqual(value["message"] as? String, "Wake screen while locked")
    XCTAssertEqual(AudioTestMarker.labels.count, 5)
    XCTAssertNil(AudioTestMarker.event("unknown", at: 1, utc: "now", origin: 0))
    XCTAssertNil(AudioTestMarker.event("lock", at: .nan, utc: "now", origin: 0))
    XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: value))
  }
}
