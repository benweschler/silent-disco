import XCTest
@testable import AudioCore

final class AudioStallTests: XCTestCase {
  func testPassAttributionAndSlowEventSuppression() throws {
    var p = RendererPassDiagnostics()
    p.begin(at: 1)
    p.stage("opusDecode", seconds: 0.015); p.decoded()
    p.stage("opusDecode", seconds: 0.015); p.decoded()
    XCTAssertEqual(p.partial(at: 1.03)["decodedFrames"] as? Int, 2)
    XCTAssertNotNil(p.finish(at: 1.04))
    p.begin(at: 1.1); p.stage("timestampRead", seconds: 0.025)
    let evidence = p.json(at: 1.12)
    let previous = try XCTUnwrap(evidence["completedPass"] as? [String: Any])
    let partial = try XCTUnwrap(evidence["currentPartialPass"] as? [String: Any])
    XCTAssertEqual(previous["sequence"] as? Int, 1)
    XCTAssertEqual(partial["sequence"] as? Int, 2)
    XCTAssertEqual(previous["decodedFrames"] as? Int, 2)
    XCTAssertNil(p.finish(at: 1.13))
    XCTAssertEqual(p.json(at: 1.13)["suppressedSlowPassEvents"] as? Int, 1)
    p.begin(at: 2.2); XCTAssertNotNil(p.finish(at: 2.23))
    XCTAssertEqual(p.json(at: 2.23)["decodedFrames"] as? Int, 2)
    let maxima = try XCTUnwrap(p.json(at: 2.23)["stageMaxPassMs"] as? [String: Double])
    XCTAssertEqual(maxima["opusDecode"], 30)
    p = RendererPassDiagnostics()
    XCTAssertEqual(p.json(at: 3)["slowPassCount"] as? Int, 0)
  }
  func testObservationWindowBoundsCadenceAndInvalidValues() throws {
    var ring = TimingObservationWindow()
    ring.append(at: .nan, fields: [:])
    for i in 0..<20 { ring.append(at: Double(i) * 0.11, fields: ["sample": i]) }
    ring.append(at: 2.10, fields: ["sample": 999])
    XCTAssertEqual(ring.observations.count, 16)
    XCTAssertEqual(ring.observations.first?["sample"] as? Int, 4)
    let invalid = PlaybackTiming(nodeHost: .infinity, sampleTime: nil, sampleRate: .nan,
      offset: 0, presentationAnchor: 0,
      latency: PlaybackLatency(hardware: .nan, pipeline: .nan, ioBuffer: nil))
    ring.append(at: 3, fields: invalid.json(scheduled: 0, rate: 1))
    XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ring.observations))
    ring = TimingObservationWindow()
    XCTAssertTrue(ring.observations.isEmpty)
  }
  func testObservationTrimmingPreservesResetAndFinalCounters() throws {
    let observations = (0..<16).map { ["index": $0, "detail": String(repeating: "x", count: 2000)] as [String: Any] }
    var omissions = 0
    let frame = DiagnosticControlFrame.prepare([
      "type": "stats", "final": true,
      "stats": ["received": 100, "diagnostics": ["events": [
        ["generation": "7", "sequence": 1, "kind": "playbackReset", "timingObservations": observations]
      ]]]], omissions: &omissions)
    XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: frame).count, 16384)
    XCTAssertEqual(omissions, 0)
    XCTAssertEqual(frame["final"] as? Bool, true)
    let stats = try XCTUnwrap(frame["stats"] as? [String: Any])
    XCTAssertEqual(stats["received"] as? Int, 100)
    let evidence = try XCTUnwrap(stats["diagnostics"] as? [String: Any])
    let events = try XCTUnwrap(evidence["events"] as? [[String: Any]])
    XCTAssertEqual(events.count, 1)
    let retained = try XCTUnwrap(events[0]["timingObservations"] as? [[String: Any]])
    XCTAssertEqual(retained.last?["index"] as? Int, 15)
    XCTAssertGreaterThan(evidence["observationOmissions"] as? Int ?? 0, 0)
    var host = ReceivedAudioDiagnostics(); host.merge(events, generation: 7)
    XCTAssertEqual(host.events.first?["kind"] as? String, "playbackReset")
  }
  func testTransportAndSenderAggregation() throws {
    var t = TransportTimerDiagnostics()
    t.tick(1); t.tick(1.1); t.tick(1.4); t.tick(2)
    XCTAssertEqual(t.json["gapCounts"] as? [Int], [2, 2, 1])
    var s = SenderDiagnostics(); s.record("source", seconds: 0.080); s.record("source", seconds: 0.002)
    XCTAssertEqual(s.json["measurementCounts"] as? [String: Int], ["source": 2])
    let excess = try XCTUnwrap(s.json["excessCounts"] as? [String: [Int]])
    XCTAssertEqual(excess["source"], [1, 1, 0])
    s = SenderDiagnostics()
    XCTAssertTrue((s.json["measurementCounts"] as? [String: Int] ?? [:]).isEmpty)
  }
}
