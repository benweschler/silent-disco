import XCTest
@testable import AudioCore

final class AudioTimingTests: XCTestCase {
  func observation(hardware: Double = 0.16, pipeline: Double = 0.21,
    host: Double? = 100, samples: Int64? = 48000, sampleRate: Double = 48000) -> PlaybackTiming {
    PlaybackTiming(nodeHost: host, sampleTime: samples, sampleRate: sampleRate,
      offset: 2, presentationAnchor: 101.21,
      latency: PlaybackLatency(hardware: hardware, pipeline: pipeline, ioBuffer: 0.01))
  }
  func testPipelineLatencyCorrectsHardwareOnlyBiasWithoutMovingAnchor() {
    let value = observation()
    XCTAssertEqual(value.error ?? 1, 0, accuracy: 0.000001)
    let fields = value.json(scheduled: 52800, rate: 1)
    XCTAssertEqual(fields["hardwareOnlyTimingErrorMs"] as? Double ?? 0, -50, accuracy: 0.000001)
    XCTAssertEqual(observation(pipeline: 0.26).error ?? 0, 0.05, accuracy: 0.000001)
    XCTAssertEqual(value.presentationAnchor, 101.21)
  }
  func testSourceSampleTimeAndNonUnitRateAreNotDoubleCounted() {
    let value = observation(samples: 96000)
    XCTAssertEqual(value.error ?? 0, -1, accuracy: 0.000001)
    XCTAssertEqual(value.json(scheduled: 100800, rate: 2)["estimatedPlayableAudioMs"] as? Double ?? 0,
      50, accuracy: 0.000001)
    XCTAssertEqual(value.error, observation(samples: 96000).error)
  }
  func testUnderrunDoesNotWaitForTimingConfirmation() {
    let value = observation(samples: 48000)
    XCTAssertTrue(value.hasUnderrun(scheduled: 46080))
    XCTAssertFalse(value.hasUnderrun(scheduled: 48000))
    var decision = SustainedTimingError()
    XCTAssertFalse(decision.observe(error: 0.060, at: 0).reset)
    // Even at the first observation the renderer can detect exhausted scheduled audio.
    XCTAssertTrue(value.hasUnderrun(scheduled: 46080))
  }
  func testInvalidTimingProducesJSONNulls() throws {
    for value in [observation(host: nil), observation(host: .nan), observation(samples: nil),
      observation(sampleRate: 0), observation(pipeline: .infinity), observation(pipeline: -1)] {
      XCTAssertNil(value.error)
      let fields = value.json(scheduled: 100, rate: 1)
      XCTAssertTrue(fields["timingErrorMs"] is NSNull)
      XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: fields))
    }
  }
  func testSpikeRecoversButSustainedSameSignResets() {
    var d = SustainedTimingError()
    XCTAssertEqual(d.observe(error: -0.060, at: 0).transition, "timingCandidateStarted")
    XCTAssertFalse(d.observe(error: -0.060, at: 0.05).reset)
    XCTAssertEqual(d.observe(error: 0.01, at: 0.1).transition, "timingCandidateRecovered")
    XCTAssertFalse(d.observe(error: 0.06, at: 1).reset)
    XCTAssertFalse(d.observe(error: 0.06, at: 1.08).reset)
    XCTAssertFalse(d.observe(error: 0.06, at: 1.16).reset)
    XCTAssertTrue(d.observe(error: 0.06, at: 1.24).reset)
  }
  func testSignGapAndInvalidObservationRestartConfirmation() {
    var d = SustainedTimingError()
    _ = d.observe(error: 0.06, at: 0)
    XCTAssertEqual(d.observe(error: -0.06, at: 0.05).transition, "timingCandidateReplaced")
    XCTAssertEqual(d.observe(error: -0.06, at: 0.20).transition, "timingCandidateReplaced")
    XCTAssertFalse(d.observe(error: -0.06, at: 0.25).reset)
    XCTAssertEqual(d.observe(error: nil, at: 0.26).transition, "timingCandidateInvalidated")
    XCTAssertFalse(d.observe(error: -0.06, at: 0.27).reset)
    d.clear()
    XCTAssertEqual(d.observe(error: -0.06, at: 0.28).transition, "timingCandidateStarted")
  }
}
