import Foundation
import XCTest
@testable import AudioCore

final class AudioSchedulerTests: XCTestCase {
  private func packet(_ n: UInt64, presentation: Double? = nil, generation: UInt64 = 1) -> AudioPacket {
    AudioPacket(token: Data(repeating: 1, count: 16), generation: generation,
      sequence: n, sample: n * 960, presentation: presentation ?? (10 + Double(n) * 0.020),
      payload: Data([1]))
  }
  func testMailboxCoalescesAndBoundsAllEncodedStorage() {
    let mailbox = AudioPacketMailbox()
    mailbox.begin(1, stored: 90)
    for n in 0..<10 { XCTAssertTrue(mailbox.offer(packet(UInt64(n)), at: Double(n))) }
    XCTAssertFalse(mailbox.offer(packet(10), at: 10))
    XCTAssertFalse(mailbox.offer(packet(1), at: 10))
    XCTAssertFalse(mailbox.offer(packet(11, generation: 2), at: 10))
    XCTAssertEqual(mailbox.drain().count, 10)
    // A drained batch reserves capacity until the scheduler accounts for it.
    XCTAssertFalse(mailbox.offer(packet(12), at: 12))
    mailbox.account(stored: 99)
    XCTAssertTrue(mailbox.offer(packet(12), at: 12))
    XCTAssertEqual(mailbox.json["overflow"] as? Int, 2)
    XCTAssertEqual(mailbox.json["duplicates"] as? Int, 1)
    XCTAssertEqual(mailbox.suspend().first?.packet.sequence, 12)
    XCTAssertFalse(mailbox.offer(packet(13), at: 13))
    mailbox.begin(2)
    XCTAssertTrue(mailbox.drain().isEmpty)
    XCTAssertFalse(mailbox.offer(packet(13), at: 13))
  }
  func testMissingPacketWaitsUntilConsumptionGuardAndCannotReplacePLC() {
    var jitter = AudioJitterBuffer()
    jitter.begin(at: 1)
    XCTAssertEqual(SchedulingPolicy.action(headroom: 0.099, packetAvailable: false,
      consecutiveLosses: 0, atEnd: false), .wait)
    jitter.insert(packet(1), hostNow: 9.99, outputLead: 0, enforcePresentationDeadline: false)
    XCTAssertEqual(SchedulingPolicy.action(headroom: 0.021, packetAvailable: jitter.nextPacket != nil,
      consecutiveLosses: 0, atEnd: false), .packet)
    XCTAssertNotNil(jitter.take())
    XCTAssertEqual(SchedulingPolicy.action(headroom: 0.019, packetAvailable: false,
      consecutiveLosses: 0, atEnd: false), .conceal)
    XCTAssertNil(jitter.take()); jitter.markConcealed(2)
    jitter.insert(packet(2), hostNow: 10, outputLead: 0, enforcePresentationDeadline: false)
    XCTAssertNil(jitter.packets[2])
    XCTAssertEqual(jitter.lateAfterConcealment, 1)
    jitter.rejoin()
    jitter.insert(packet(1), hostNow: 9, outputLead: 0)
    jitter.insert(packet(2), hostNow: 9, outputLead: 0)
    XCTAssertTrue(jitter.packets.isEmpty) // committed sequences stay committed across a rejoin
  }
  func testSixMissingFramesAndRecoveryPreserveFuturePackets() {
    var jitter = AudioJitterBuffer(); jitter.begin(at: 0)
    for i in 0..<6 {
      XCTAssertEqual(SchedulingPolicy.action(headroom: 0.010, packetAvailable: false,
        consecutiveLosses: i, atEnd: false), .conceal)
      XCTAssertNil(jitter.take()); jitter.markConcealed(UInt64(i))
    }
    jitter.insert(packet(9), hostNow: 10, outputLead: 0)
    jitter.insert(packet(7), hostNow: 10, outputLead: 0)
    jitter.insert(packet(8), hostNow: 10, outputLead: 0)
    XCTAssertEqual(jitter.maximumReorderDepth, 2)
    XCTAssertEqual(SchedulingPolicy.action(headroom: 0.010, packetAvailable: true,
      consecutiveLosses: 6, atEnd: false), .exhausted)
    jitter.rejoin()
    XCTAssertEqual(jitter.contiguousPackets, 3)
    jitter.discard(before: 10.13)
    jitter.begin(at: 7)
    XCTAssertEqual(jitter.take()?.sequence, 7)
    XCTAssertEqual(jitter.packets.count, 2)
  }
  func testConsumptionRefillIgnoresMisleadingSourceDeadline() throws {
    let latency = PlaybackLatency(hardware: 0.163, pipeline: 0.164, ioBuffer: 0.01)
    let timing = PlaybackTiming(nodeHost: 100, sampleTime: 48000, sampleRate: 48000,
      offset: 0, presentationAnchor: 99.164, latency: latency)
    // 250 ms of source frames, consumed at the observed lock transition rate.
    let fast = try XCTUnwrap(SchedulingPolicy.headroom(scheduled: 60000, timing: timing,
      now: 100, start: 99, rate: 1, outputSlope: 1.117))
    let slow = try XCTUnwrap(SchedulingPolicy.headroom(scheduled: 60000, timing: timing,
      now: 100, start: 99, rate: 1, outputSlope: 0.906))
    XCTAssertLessThan(fast, SchedulingPolicy.target)
    XCTAssertGreaterThan(slow, SchedulingPolicy.target)
    XCTAssertEqual(SchedulingPolicy.action(headroom: fast, packetAvailable: true,
      consecutiveLosses: 0, atEnd: false), .packet)
    XCTAssertEqual(SchedulingPolicy.action(headroom: slow, packetAvailable: true,
      consecutiveLosses: 0, atEnd: false), .wait)
    let afterWork = try XCTUnwrap(SchedulingPolicy.headroom(scheduled: 60000, timing: timing,
      now: 100.085, start: 99, rate: 1, outputSlope: 1.117))
    XCTAssertEqual(fast - afterWork, 0.085, accuracy: 0.000001)
    XCTAssertNil(SchedulingPolicy.headroom(scheduled: 60000, timing: nil,
      now: 100, start: 99, rate: 1, outputSlope: 1))
    XCTAssertEqual(SchedulingPolicy.action(headroom: nil, packetAvailable: false,
      consecutiveLosses: 0, atEnd: false), .wait)
    XCTAssertEqual(SchedulingPolicy.action(headroom: -1, packetAvailable: false,
      consecutiveLosses: 0, atEnd: true), .wait) // no PLC beyond end-of-stream
  }
  func testEightHundredMillisecondDeliveryGapFitsSharedLead() {
    // Each frame is sent at its source time, becomes available 800 ms later,
    // and is consumed 1250 - 164 - 6.5 ms after the source time.
    var jitter = AudioJitterBuffer(); jitter.begin(at: 0)
    let renderLead = 1.250 - 0.164 - 0.0065
    var scheduled = 0
    var losses = 0
    var nextArrival = 0
    for tick in 0..<800 {
      let now = Double(tick) * 0.005
      while nextArrival < 150 && Double(nextArrival) * 0.020 + 0.800 <= now {
        let n = UInt64(nextArrival)
        jitter.insert(packet(n, presentation: 1.250 - 0.0065 + Double(n) * 0.020),
          hostNow: now, outputLead: 0.164, enforcePresentationDeadline: false)
        nextArrival += 1
      }
      for _ in 0..<6 {
        let remaining = Double(scheduled) * 0.020 - (now - renderLead)
        let action = SchedulingPolicy.action(headroom: remaining,
          packetAvailable: jitter.nextPacket != nil, consecutiveLosses: losses,
          atEnd: scheduled >= 150)
        guard action == .packet || action == .conceal else { break }
        if jitter.take() == nil { losses += 1 }
        scheduled += 1
      }
    }
    XCTAssertEqual(losses, 0)
    XCTAssertGreaterThan(scheduled, 140)
    XCTAssertLessThan(jitter.packets.count, 100)
  }
  func testGapsBeyondTheSharedBudgetCommitOnlySixPLCFrames() {
    for gap in [1.250, 2.200] {
      var jitter = AudioJitterBuffer(); jitter.begin(at: 0)
      let renderLead = 1.250 - 0.164 - 0.0065
      var queued = 0; var losses = 0; var arrivals = 0
      for tick in 0..<800 {
        let now = Double(tick) * 0.005
        while arrivals < 100 && Double(arrivals) * 0.020 + gap <= now {
          let n = UInt64(arrivals)
          jitter.insert(packet(n, presentation: 1.250 - 0.0065 + Double(n) * 0.020),
            hostNow: now, outputLead: 0.164, enforcePresentationDeadline: false)
          arrivals += 1
        }
        let action = SchedulingPolicy.action(headroom: Double(queued) * 0.020 - (now - renderLead),
          packetAvailable: jitter.nextPacket != nil, consecutiveLosses: losses, atEnd: false)
        if action == .conceal || action == .packet {
          if jitter.take() == nil { losses += 1; jitter.markConcealed(UInt64(queued)) }
          queued += 1
        }
      }
      XCTAssertEqual(losses, 6)
      XCTAssertEqual(jitter.lateAfterConcealment, 6)
      XCTAssertNil(jitter.packets[0])
      XCTAssertEqual(SchedulingPolicy.action(headroom: -1, packetAvailable: true,
        consecutiveLosses: losses, atEnd: false), .exhausted)
      // A recovery can retain future arrivals but may not replace committed PLC.
      jitter.rejoin()
      XCTAssertNotNil(jitter.first)
      XCTAssertGreaterThan(jitter.first!.sequence, 5)
    }
  }
  func testLeadCapabilityDefaultsAndLegacyCompatibility() {
    XCTAssertEqual(AudioLeadPolicy.maximum(nil), 1000)
    XCTAssertFalse(AudioLeadPolicy.supports(1.25, maximum: AudioLeadPolicy.maximum(nil)))
    XCTAssertTrue(AudioLeadPolicy.supports(1.0, maximum: AudioLeadPolicy.maximum(nil)))
    XCTAssertTrue(AudioLeadPolicy.supports(1.25, maximum: AudioLeadPolicy.maximum(1250)))
    XCTAssertEqual(AudioLeadPolicy.maximum(Int.max), 1250)
    XCTAssertTrue(AudioLeadPolicy.choices.contains(1250))
  }
}

final class AudioLatencyTests: XCTestCase {
  private func snapshot(epoch: UInt64, started: Double, pipeline: Double = 0.164) -> LatencySnapshot {
    LatencySnapshot(epoch: epoch, started: started, captured: started + 0.085,
      value: PlaybackLatency(hardware: 0.163, pipeline: pipeline, ioBuffer: 0.01), diagnostics: [:])
  }
  func testEpochAndValidityRejectStaleRefreshesWithoutLosingGoodValue() {
    var store = LatencySnapshotStore(); store.begin(1)
    XCTAssertTrue(store.accept(snapshot(epoch: 1, started: 10)))
    XCTAssertFalse(store.accept(snapshot(epoch: 1, started: 11, pipeline: .nan)))
    XCTAssertEqual(store.snapshot?.started, 10)
    XCTAssertFalse(store.accept(snapshot(epoch: 1, started: 9)))
    XCTAssertTrue(store.snapshot!.age(at: 13.1) > 3)
    store.begin(2)
    XCTAssertNil(store.snapshot)
    XCTAssertFalse(store.accept(snapshot(epoch: 1, started: 12)))
    XCTAssertTrue(store.accept(snapshot(epoch: 2, started: 12)))
  }
  func testBlockedGetterDoesNotBlockSchedulingAndRequestsCoalesce() {
    let control = AudioControlQueue()
    let entered = expectation(description: "getter entered")
    let completed = expectation(description: "getter finished")
    let gate = DispatchSemaphore(value: 0)
    XCTAssertTrue(control.refresh(read: {
      entered.fulfill()
      _ = gate.wait(timeout: .now() + 2)
      return self.snapshot(epoch: 1, started: 10)
    }, deliver: { _ in completed.fulfill() }))
    wait(for: [entered], timeout: 1)
    XCTAssertFalse(control.refresh(read: { XCTFail("duplicate getter"); return self.snapshot(epoch: 1, started: 11) }, deliver: { _ in }))
    let scheduler = DispatchQueue(label: "test.scheduler")
    let scheduled = expectation(description: "scheduler progresses while getter is blocked")
    scheduler.asyncAfter(deadline: .now() + 0.100) {
      XCTAssertEqual(SchedulingPolicy.action(headroom: 0.080, packetAvailable: true,
        consecutiveLosses: 0, atEnd: false), .packet)
      scheduled.fulfill()
    }
    wait(for: [scheduled], timeout: 0.5)
    gate.signal()
    wait(for: [completed], timeout: 1)
  }
  func testSnapshotSerializationDoesNotInvokeAGetter() throws {
    let value = snapshot(epoch: 3, started: 100)
    let data = try JSONSerialization.data(withJSONObject: value.json(at: 104))
    XCTAssertFalse(data.isEmpty)
    XCTAssertEqual(value.json(at: 104)["stale"] as? Bool, true)
  }
}
