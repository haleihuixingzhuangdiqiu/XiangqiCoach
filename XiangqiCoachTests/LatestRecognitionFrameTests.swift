import XCTest
@testable import XiangqiCoach

final class LatestRecognitionFrameTests: XCTestCase {
    func testBurstContinuesWithNewestFrameImmediatelyWithoutAnotherCapture() throws {
        var frames = LatestRecognitionFrame<String>()
        let first = try XCTUnwrap(frames.offer("旧局面", capturedAt: 10))
        XCTAssertNil(frames.offer("动画中", capturedAt: 10.1))
        XCTAssertNil(frames.offer("最新落子", capturedAt: 10.2))
        let next = try XCTUnwrap(frames.complete(first, now: 10.3))
        XCTAssertEqual(next.value, "最新落子")
        XCTAssertEqual(next.capturedAt, 10.2)
        XCTAssertTrue(frames.isCurrent(next))
        XCTAssertNil(frames.complete(next, now: 10.4))
        XCTAssertNotNil(frames.offer("后续确认帧", capturedAt: 10.5))
    }

    func testStoppedSessionCannotReleaseOrReplayNewSessionWork() throws {
        var frames = LatestRecognitionFrame<Int>()
        let old = try XCTUnwrap(frames.offer(1, capturedAt: 10))
        XCTAssertNil(frames.offer(2, capturedAt: 10.1))
        frames.reset()
        let current = try XCTUnwrap(frames.offer(3, capturedAt: 11))
        XCTAssertNil(frames.offer(4, capturedAt: 11.1))
        XCTAssertFalse(frames.isCurrent(old))
        XCTAssertNil(frames.complete(old, now: 11.2))
        XCTAssertTrue(frames.isCurrent(current))
        XCTAssertEqual(frames.complete(current, now: 11.2)?.value, 4)
    }

    func testOutOfOrderAndDuplicateFramesCannotReplaceLatestCandidate() throws {
        var frames = LatestRecognitionFrame<Int>()
        let first = try XCTUnwrap(frames.offer(1, capturedAt: 10))
        XCTAssertNil(frames.offer(3, capturedAt: 10.3))
        XCTAssertNil(frames.offer(2, capturedAt: 10.2))
        XCTAssertNil(frames.offer(4, capturedAt: 10.3))
        XCTAssertNil(frames.offer(5, capturedAt: .nan))
        XCTAssertEqual(frames.complete(first, now: 10.4)?.value, 3)
    }

    func testPendingFrameExpiresWithoutBlockingNextFreshCapture() throws {
        for now in [9.0, 12.0, Double.infinity] {
            var frames = LatestRecognitionFrame<Int>()
            let first = try XCTUnwrap(frames.offer(1, capturedAt: 10))
            XCTAssertNil(frames.offer(2, capturedAt: 10.1))
            XCTAssertNil(frames.complete(first, now: now))
            XCTAssertNotNil(frames.offer(3, capturedAt: 12.1))
        }
    }
}
