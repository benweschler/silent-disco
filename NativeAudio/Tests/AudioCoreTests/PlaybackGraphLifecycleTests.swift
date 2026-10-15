import AVFoundation
import XCTest
@testable import AudioCore

final class PlaybackGraphLifecycleTests: XCTestCase {
  private func offlineEngine(format: AVAudioFormat) throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 960)
    return engine
  }

  func testRepeatedPlaybackAndTeardownReleasesEngineOwnedNodes() throws {
    for epoch in 1...10 {
      weak var retiredEngine: AVAudioEngine?
      weak var retiredOutput: AVAudioOutputNode?
      weak var retiredMixer: AVAudioMixerNode?
      try autoreleasepool {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        // The graph is the sole engine owner, matching production teardown.
        let graph = try PlaybackGraph(epoch: UInt64(epoch), engine: offlineEngine(format: format))
        retiredEngine = graph.engine
        retiredOutput = graph.output
        retiredMixer = graph.mixer
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        pcm.frameLength = 960
        for channel in 0..<2 {
          for frame in 0..<960 { pcm.floatChannelData![channel][frame] = 0 }
        }
        graph.player.scheduleBuffer(pcm)
        graph.player.play()
        XCTAssertEqual(try graph.engine.renderOffline(960, to: pcm), .success)
        graph.stop()
      }
      XCTAssertNil(retiredEngine)
      XCTAssertNil(retiredOutput)
      XCTAssertNil(retiredMixer)
    }
  }
}
