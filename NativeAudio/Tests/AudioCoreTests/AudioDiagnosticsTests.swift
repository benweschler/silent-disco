import XCTest
@testable import AudioCore

final class AudioDiagnosticsTests: XCTestCase {
  func testCallbackGapsAndResetBoundaryPreserveRunTotals() {
    var m = RenderMeasurements()
    m.tick(1); m.tick(1.025); m.tick(1.080); m.tick(1.200)
    m.pass(0.003); m.packetQueue(0.040)
    let beforeCleanup = m.json
    m.resetBoundary()
    XCTAssertEqual(beforeCleanup["timerGapCounts"] as? [Int], [3, 2, 1])
    XCTAssertEqual(beforeCleanup["maxTimerIntervalSinceResetMs"] as? Double ?? 0, 120, accuracy: 0.001)
    XCTAssertEqual(m.json["maxTimerIntervalSinceResetMs"] as? Double, 0)
    XCTAssertEqual(m.json["timerGapCounts"] as? [Int], [3, 2, 1])
    XCTAssertEqual(m.json["maxPacketQueueDelayMs"] as? Double, 40)
    m = RenderMeasurements()
    XCTAssertEqual(m.json["timerGapCounts"] as? [Int], [0, 0, 0])
  }
  func testPlayableEstimateHandlesRatesAndUnavailableTiming() {
    XCTAssertEqual(RenderMeasurements.playableMs(scheduled: 9600, sampleTime: 4800,
      sampleRate: 48000, rate: 2), 50)
    XCTAssertEqual(RenderMeasurements.playableMs(scheduled: 960, sampleTime: 4800,
      sampleRate: 48000, rate: 1), 0)
    XCTAssertNil(RenderMeasurements.playableMs(scheduled: 960, sampleTime: nil,
      sampleRate: 48000, rate: 1))
    XCTAssertNil(RenderMeasurements.playableMs(scheduled: 960, sampleTime: 0,
      sampleRate: 0, rate: 1))
  }
  func testRunEvidenceCapturesValuesBeforeCleanupAndResetsOnGeneration() {
    var d = AudioDiagnostics()
    d.begin(7)
    var fields: [String: Any] = ["scheduledSamples": 9600, "compressedBufferMs": 300]
    d.record("playbackReset", at: 10, utc: "now", offset: 2, origin: 11, fields: fields)
    fields["scheduledSamples"] = 0
    XCTAssertEqual(d.events[0]["scheduledSamples"] as? Int, 9600)
    XCTAssertEqual(d.events[0]["streamSeconds"] as? Double, 1)
    d.begin(7)
    XCTAssertEqual(d.events.count, 1)
    for i in 0..<300 { d.record("reset", at: Double(i), utc: "now", offset: 0, origin: 0) }
    XCTAssertEqual(d.events.count, 256)
    XCTAssertEqual(d.overflow, 45)
    XCTAssertEqual((d.json["events"] as? [[String: Any]])?.count, 8)
    d.begin(8)
    XCTAssertTrue(d.events.isEmpty)
    XCTAssertEqual(d.overflow, 0)
  }
  func testTransportBudgetAndFinalEvidenceAccumulation() throws {
    var d = AudioDiagnostics(); d.begin(1)
    for i in 0..<8 {
      d.record("reset", at: Double(i), utc: "now", offset: 0, origin: 0,
        fields: ["detail": String(repeating: "x", count: 3000)])
    }
    var omissions = 0
    let message = DiagnosticControlFrame.prepare([
      "type": "stats", "generation": "1", "final": true,
      "stats": ["received": 12, "diagnostics": d.json]], omissions: &omissions)
    XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: message).count, 16384)
    XCTAssertGreaterThan(omissions, 0)
    XCTAssertEqual(message["final"] as? Bool, true)
    let stats = try XCTUnwrap(message["stats"] as? [String: Any])
    let evidence = try XCTUnwrap(stats["diagnostics"] as? [String: Any])
    let events = try XCTUnwrap(evidence["events"] as? [[String: Any]])
    var host = ReceivedAudioDiagnostics()
    host.merge(events, generation: 1); host.merge(events, generation: 1)
    XCTAssertEqual(host.events.count, events.count)
    XCTAssertEqual(host.gaps, omissions)
    XCTAssertEqual(host.json(evidence)["transportOmissions"] as? Int, omissions)
    host.merge([["generation": "2", "sequence": 100]], generation: 1)
    XCTAssertEqual(host.events.count, events.count)
    for i in 9...280 { host.merge([["generation": "1", "sequence": i]], generation: 1) }
    XCTAssertEqual(host.events.count, 256)
    XCTAssertGreaterThan(host.overflow, 0)
  }
}
