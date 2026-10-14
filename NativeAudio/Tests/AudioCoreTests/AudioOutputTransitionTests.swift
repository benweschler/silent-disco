import XCTest
@testable import AudioCore

final class AudioOutputTransitionTests: XCTestCase {
  private func point(_ t: Double, samples: Double? = nil, epoch: UInt64 = 1) -> OutputClockPoint {
    OutputClockPoint(epoch: epoch, captured: t, host: t,
      samples: Int64(((samples ?? t) * 48000).rounded()), sampleRate: 48000,
      playerSamples: nil, rateScalar: nil)
  }
  func testRecordedLockAndWakeWindowsDoNotTriggerRawPhaseResets() {
    // Reduced from 1791858577154-15516820537730259269.json, resets at 6.919/18.412 s.
    // Capture, output host, output samples, player samples, raw phase error (ms).
    let fixtures: [[(Double, Double, Int64, Int64, Double)]] = [
      [(129492.16879550001,129492.18722929168,6213968161,320399,-19.756673),
       (129492.26879970834,129492.28560825001,6213973441,325677,-31.313590),
       (129492.37008462501,129492.38406541667,6213978721,330953,-42.771048),
       (129492.47370845835,129492.49084458334,6213984481,336710,-55.937381),
       (129492.57375037501,129492.58955254167,6213989761,341990,-67.229423)],
      [(129503.678363875,129503.69844837501,6214523521,513430,28.808177),
       (129503.77868091667,129503.7974505,6214527841,517753,37.745636),
       (129503.87894604167,129503.89723558334,6214532161,522077,47.467802),
       (129503.98334408335,129503.99621320835,6214536481,526398,56.412094),
       (129504.08346333334,129504.106560125,6214541281,531198,66.759011)]
    ]
    for rows in fixtures {
      var controller = PlaybackTimingController(); controller.restart(epoch: 1)
      for row in rows {
        let p = OutputClockPoint(epoch: 1, captured: row.0, host: row.1,
          samples: row.2, sampleRate: 48000, playerSamples: row.3, rateScalar: nil)
        let decision = controller.observe(p, error: row.4 / 1000, latencyFresh: true, at: row.0)
        XCTAssertNil(decision.recovery)
        XCTAssertFalse(decision.correctionAllowed)
      }
      XCTAssertEqual(controller.state, .outputTransition)
      let expected = rows[0].4 < 0 ? 1.117 : 0.906
      XCTAssertEqual(controller.slope, expected, accuracy: 0.005)
    }
  }
  func testTransitionTimeoutAllowsOnlyOneRecoveryAcrossRestarts() {
    var c = PlaybackTimingController(); c.restart(epoch: 1)
    var recoveries = 0
    var epoch: UInt64 = 1
    for i in 0...160 {
      let t = Double(i) * 0.05
      let result = c.observe(point(t, samples: t * 1.117, epoch: epoch),
        error: -0.070, latencyFresh: true, at: t)
      if result.recovery != nil {
        recoveries += 1; epoch += 1; c.restart(epoch: epoch)
      }
    }
    XCTAssertEqual(recoveries, 1)
  }
  func testStableReacquisitionThenSustainedResidualPhaseRejoinsOnce() {
    var c = PlaybackTimingController(); c.restart(epoch: 1)
    for i in 0...20 {
      let t = Double(i) * 0.05
      XCTAssertNil(c.observe(point(t, samples: t * 0.906), error: 0.070,
        latencyFresh: true, at: t).recovery)
    }
    var recoveries = 0
    for i in 21...60 {
      let t = Double(i) * 0.05
      let result = c.observe(point(t, samples: 0.906 + t - 1), error: 0.070,
        latencyFresh: true, at: t)
      if t < 1.5 { XCTAssertFalse(result.correctionAllowed) }
      if result.recovery != nil { recoveries += 1 }
    }
    XCTAssertEqual(recoveries, 1)
    // A recovered, stable phase releases the latch for a later independent episode.
    for i in 61...90 {
      let t = Double(i) * 0.05
      _ = c.observe(point(t, samples: 0.906 + t - 1), error: 0.001, latencyFresh: true, at: t)
    }
    XCTAssertEqual(c.summary["recoveryUsed"] as? Bool, false)
  }
  func testInvalidAndStaleObservationsNeverAuthorizeTimingCorrection() {
    var c = PlaybackTimingController(); c.restart(epoch: 1)
    for i in 0...30 {
      let t = Double(i) * 0.05
      _ = c.observe(point(t), error: 0.005, latencyFresh: true, at: t)
    }
    XCTAssertEqual(c.state, .stable)
    XCTAssertFalse(c.observe(point(1.55), error: 0.005, latencyFresh: false, at: 1.55).correctionAllowed)
    XCTAssertEqual(c.state, .timingUnavailable)
    XCTAssertFalse(c.observe(nil, error: nil, latencyFresh: true, at: 1.6).correctionAllowed)
    XCTAssertFalse(c.observe(point(1.65, epoch: 2), error: 0.070,
      latencyFresh: true, at: 1.65).correctionAllowed)
    XCTAssertFalse(c.observe(point(1.7, samples: -1), error: 0.070,
      latencyFresh: true, at: 1.7).correctionAllowed)
  }
  func testSourceAnchorAndClockAdjustmentSurviveLocalPlaybackEpochs() throws {
    let latency = PlaybackLatency(hardware: 0.163, pipeline: 0.164, ioBuffer: 0.01)
    var timing = PlaybackTiming(nodeHost: 110, sampleTime: 48000, sampleRate: 48000,
      offset: 2, presentationAnchor: 101.164, latency: latency, sourceSampleBase: 480000)
    XCTAssertEqual(try XCTUnwrap(timing.error), 0, accuracy: 0.000001)
    timing = PlaybackTiming(nodeHost: 110, sampleTime: 48000, sampleRate: 48000,
      offset: 2.002, presentationAnchor: 101.164, latency: latency, sourceSampleBase: 480000)
    XCTAssertEqual(try XCTUnwrap(timing.error), 0.002, accuracy: 0.000001)
    // Choosing a later local source origin changes the consumed source position,
    // not the fixed Mac presentation reference.
    let restarted = PlaybackTiming(nodeHost: 110.5, sampleTime: 0, sampleRate: 48000,
      offset: 2.002, presentationAnchor: 101.164, latency: latency, sourceSampleBase: 552000)
    XCTAssertEqual(restarted.presentationAnchor, timing.presentationAnchor)
    XCTAssertEqual(try XCTUnwrap(restarted.error), 0.002, accuracy: 0.000001)
  }
  func testStaleLatencyAloneNeverStopsOtherwiseHealthyPlayback() {
    var c = PlaybackTimingController(); c.restart(epoch: 1)
    for i in 0...200 {
      let t = Double(i) * 0.05
      let decision = c.observe(point(t), error: 0.070, latencyFresh: false, at: t)
      XCTAssertFalse(decision.correctionAllowed)
      XCTAssertNil(decision.recovery)
    }
  }
  func testCompactTransitionSummarySurvivesObservationTrimming() throws {
    var c = PlaybackTimingController(); c.restart(epoch: 1)
    for i in 0...10 {
      let t = Double(i) * 0.05
      _ = c.observe(point(t, samples: t * 1.117), error: -0.070, latencyFresh: true, at: t)
    }
    var omitted = 0
    let frame = DiagnosticControlFrame.prepare(["type": "stats", "final": true,
      "stats": ["diagnostics": ["events": [["kind": "playbackReset", "sequence": 1,
        "generation": "1", "timingSummary": c.summary,
        "timingObservations": (0..<16).map { ["sample": $0, "detail": String(repeating: "x", count: 2000)] }
      ]]]]], omissions: &omitted)
    let stats = try XCTUnwrap(frame["stats"] as? [String: Any])
    let diagnostics = try XCTUnwrap(stats["diagnostics"] as? [String: Any])
    let events = try XCTUnwrap(diagnostics["events"] as? [[String: Any]])
    let summary = try XCTUnwrap(events.first?["timingSummary"] as? [String: Any])
    XCTAssertEqual(summary["state"] as? String, "outputTransition")
    XCTAssertNotNil(summary["start"]); XCTAssertNotNil(summary["end"])
    XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: frame).count, 16384)
  }
}
