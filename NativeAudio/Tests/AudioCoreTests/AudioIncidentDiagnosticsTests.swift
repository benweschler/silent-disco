import XCTest
@testable import AudioCore

final class AudioIncidentDiagnosticsTests: XCTestCase {
  func testIndividualCallAttributionAndBoundedSlowCalls() throws {
    var calls = AudioCallMeasurements()
    for (i, name) in ["player.lastRenderTime", "playerTime(forNodeTime:)", "output.lastRenderTime"].enumerated() {
      for n in 0..<20 { calls.record(name, site: "scheduler", start: Double(n), end: Double(n) + 0.085 + Double(i) * 0.005, graph: 3, playback: 9) }
    }
    let aggregate = try XCTUnwrap(calls.json["aggregate"] as? [String: Any])
    let maxima = try XCTUnwrap(aggregate["maxDurationsMs"] as? [String: Double])
    XCTAssertEqual(maxima["player.lastRenderTime"]!, 85, accuracy: 0.001)
    XCTAssertEqual(maxima["playerTime(forNodeTime:)"]!, 90, accuracy: 0.001)
    XCTAssertEqual(maxima["output.lastRenderTime"]!, 95, accuracy: 0.001)
    XCTAssertEqual((calls.json["slowCalls"] as? [[String: Any]])?.count, 16)
    XCTAssertEqual(calls.json["omittedSlowCalls"] as? Int, 44)
  }
  func testIncidentWindowsAndRecoveryLifecycleSurviveRingEviction() throws {
    var packets = PacketIncidentEvidence()
    for i in 0..<300 { packets.record(["sequence": i, "decision": "packetCommitted"]) }
    for i in 0..<10 { packets.freeze("PLC", at: Double(i)) }
    XCTAssertEqual(packets.ring.count, 256)
    XCTAssertEqual(packets.windows.count, 8)
    XCTAssertEqual((packets.windows.last?["entries"] as? [[String: Any]])?.count, 32)
    XCTAssertEqual(packets.json["ringEvictions"] as? Int, 44)
    var recovery = RecoveryTimeline()
    recovery.begin(reason: "missing", category: "missingAudio", at: 2, fields: ["availablePCMms": 120])
    recovery.update(["stopReturnedAt": 2.1, "playCallAt": 2.2, "restartSequence": "20"])
    let record = try XCTUnwrap(recovery.progressed(at: 2.5))
    XCTAssertEqual(record["stopToObservedProgressMs"] as? Double ?? 0, 400, accuracy: 0.001)
    XCTAssertEqual(record["restartSequence"] as? String, "20")
    XCTAssertNil(recovery.progressed(at: 3))
  }
  func testFinalSnapshotCannotBeDowngradedOrReplaced() {
    var snapshot = FinalListenerSnapshot()
    snapshot.accept(["received": 12], final: false, sequence: 0)
    snapshot.accept(["received": 15], final: true, sequence: 20)
    snapshot.accept(["received": 1], final: false, sequence: 0)
    snapshot.accept(["received": 99], final: true, sequence: 999)
    XCTAssertTrue(snapshot.final)
    XCTAssertEqual(snapshot.stats["received"] as? Int, 15)
    XCTAssertEqual(snapshot.diagnosticSequence, 20)
    snapshot = FinalListenerSnapshot()
    XCTAssertFalse(snapshot.final)
  }
  func testFinalSnapshotDeliveryDoesNotWaitForTeardownQueue() {
    let control = AudioControlQueue()
    let release = DispatchSemaphore(value: 0)
    control.queue.async { release.wait() }
    defer { release.signal() }
    let renderer = AudioRenderer(control: control)
    let delivered = expectation(description: "snapshot delivered before teardown")
    renderer.finalSnapshot { stats in
      XCTAssertNotNil(stats["rendererDiagnostics"])
      XCTAssertEqual(stats["missingAtDeadline"] as? Int, 0)
      delivered.fulfill()
    }
    wait(for: [delivered], timeout: 1)
  }
  func testIncrementalDeliveryRetriesDeduplicatesAndDeclaresEvictions() throws {
    var sender = AudioDiagnostics(); sender.begin(1)
    for i in 0..<300 { sender.record("test", at: Double(i), utc: "now", offset: 0, origin: 0) }
    var receiver = ReceivedAudioDiagnostics()
    let first = try XCTUnwrap(sender.batch(at: 0))
    XCTAssertNil(sender.batch(at: 0.5))
    let retry = try XCTUnwrap(sender.batch(at: 1))
    XCTAssertEqual(retry["through"] as? Int, first["through"] as? Int)
    for batch in [first, retry] {
      receiver.evict(through: batch["evictedThrough"] as? Int ?? 0)
      receiver.merge(batch["events"] as? [[String: Any]] ?? [], generation: 1)
    }
    sender.acknowledge(receiver.highest)
    while let batch = sender.batch(at: 2) {
      XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: batch).count, 16384)
      receiver.evict(through: batch["evictedThrough"] as? Int ?? 0)
      receiver.merge(batch["events"] as? [[String: Any]] ?? [], generation: 1)
      sender.acknowledge(receiver.highest)
    }
    XCTAssertTrue(sender.deliveryComplete)
    XCTAssertEqual(receiver.highest, 300)
    XCTAssertEqual(receiver.gaps, 0)
    XCTAssertEqual(receiver.json([:])["declaredTransportEvictions"] as? Int, 44)
    sender.begin(2)
    XCTAssertEqual(sender.latestSequence, 0)
    sender.acknowledge(300)
    XCTAssertTrue(sender.deliveryComplete)
  }
  func testOversizedEvidenceCannotBlockFinalCountersOrDelivery() throws {
    var sender = AudioDiagnostics(); sender.begin(1)
    sender.record("packetIncident", at: 1, utc: "now", offset: 0, origin: 0,
      fields: ["incident": ["entries": String(repeating: "x", count: 100000)]])
    let batch = try XCTUnwrap(sender.batch(at: 1))
    XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: batch).count, 16384)
    XCTAssertGreaterThan(sender.deliverySummary["detailOmissions"] as? Int ?? 0, 0)
    var omissions = 0
    let frame = DiagnosticControlFrame.prepare(["type": "stats", "final": true,
      "stats": ["received": 42, "diagnostics": ["events": []], "rendererDiagnostics": [
        "packetIncidents": String(repeating: "x", count: 100000), "recoveryTimeline": [:]]]], omissions: &omissions)
    XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: frame).count, 16384)
    XCTAssertEqual((frame["stats"] as? [String: Any])?["received"] as? Int, 42)
  }
  func testAcknowledgementStopsAtFirstUnexplainedGap() {
    var receiver = ReceivedAudioDiagnostics()
    receiver.merge([["generation": "1", "sequence": 1], ["generation": "1", "sequence": 3]], generation: 1, contiguous: true)
    XCTAssertEqual(receiver.highest, 1)
    receiver.merge([["generation": "1", "sequence": 2], ["generation": "1", "sequence": 3]], generation: 1, contiguous: true)
    XCTAssertEqual(receiver.highest, 3)
  }
  func testFinalizationWaitsForIdentityCountersAndRequiredEvidence() {
    let ids: Set<String> = ["one", "disconnected"]
    var rows: [[String: Any]] = [["id": "one", "finalCounters": true, "diagnosticDeliveryComplete": false],
      ["id": "disconnected", "finalCounters": false, "disconnectReason": "closed"]]
    XCTAssertEqual(AudioReportReadiness.evaluate(ids: ids, rows: rows)["stage"] as? String, "listenerFinalSnapshot")
    rows[1]["finalCounters"] = true; rows[1]["diagnosticDeliveryComplete"] = true
    XCTAssertEqual(AudioReportReadiness.evaluate(ids: ids, rows: rows)["stage"] as? String, "diagnosticDelivery")
    rows[0]["diagnosticDeliveryComplete"] = true
    XCTAssertEqual(AudioReportReadiness.evaluate(ids: ids, rows: rows)["ready"] as? Bool, true)
    rows.removeLast()
    XCTAssertEqual(AudioReportReadiness.evaluate(ids: ids, rows: rows)["missingFinalListeners"] as? [String], ["disconnected"])
    XCTAssertEqual(AudioReportReadiness.evaluate(ids: [], rows: [])["stage"] as? String, "noParticipants")
  }
  func testFinalCounterFallbackWhenRendererDetailsAloneExceedFrameBudget() throws {
    var omissions = 0
    let frame = DiagnosticControlFrame.prepare(["type": "stats", "generation": "1", "final": true,
      "stats": ["received": 10, "concealedFrames": 6, "diagnostics": ["events": []],
        "rendererDiagnostics": ["oversizedDetail": String(repeating: "x", count: 50000)]]], omissions: &omissions)
    XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: frame).count, 16384)
    XCTAssertEqual((frame["stats"] as? [String: Any])?["concealedFrames"] as? Int, 6)
    XCTAssertEqual((frame["stats"] as? [String: Any])?["rendererDetailsOmitted"] as? Bool, true)
  }
}
