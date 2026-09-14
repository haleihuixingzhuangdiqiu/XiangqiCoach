import CoreMedia
import XCTest
@testable import XiangqiCoach

final class FramePipelineTests: XCTestCase {
    @MainActor
    func testRapidOverlayUpdatesAreImmediateAndReuseUnchangedPixels() throws {
        let factory = OverlayFrameFactory()
        let state = CoachOverlayState()
        let before = CMClockGetTime(CMClockGetHostTimeClock())
        let first = try XCTUnwrap(factory.makeSampleBuffer(state: state))
        var last = first
        for _ in 0..<8 { last = try XCTUnwrap(factory.makeSampleBuffer(state: state)) }
        let after = CMClockGetTime(CMClockGetHostTimeClock())
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(last, createIfNecessary: false) as? [[String: Any]])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool, true)
        // 验证真实主机时间的上下界，不以主机负载决定通过与否；旧版帧数/2 时间戳不能满足此条件。
        XCTAssertGreaterThanOrEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(first), before), 0)
        XCTAssertLessThanOrEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(last), after), 0)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(last), CMSampleBufferGetPresentationTimeStamp(first)), 0)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(first) === CMSampleBufferGetImageBuffer(last))
    }

    @MainActor
    func testStaleBoardInvalidatesPixelCacheAndDropsOldArrow() throws {
        let factory = OverlayFrameFactory()
        let move = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        var state = CoachOverlayState(position: .standard, suggestedMove: move)
        let current = try XCTUnwrap(factory.makeSampleBuffer(state: state))
        state.boardIsCurrent = false
        let stale = try XCTUnwrap(factory.makeSampleBuffer(state: state))
        let repeated = try XCTUnwrap(factory.makeSampleBuffer(state: state))
        XCTAssertFalse(CMSampleBufferGetImageBuffer(current) === CMSampleBufferGetImageBuffer(stale))
        XCTAssertTrue(CMSampleBufferGetImageBuffer(stale) === CMSampleBufferGetImageBuffer(repeated))
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
        state.boardIsCurrent = true
        let restored = try XCTUnwrap(factory.makeSampleBuffer(state: state))
        XCTAssertFalse(CMSampleBufferGetImageBuffer(stale) === CMSampleBufferGetImageBuffer(restored))
        XCTAssertEqual(CoachBoardRenderer.displayedMove(for: state), move)
    }

    func testFrameHeaderPreservesCaptureTimeAndRejectsInvalidPackets() throws {
        let header = FramePacketHeader(payloadSize: 32_456, capturedAt: 14_567.123456)
        let decoded = try XCTUnwrap(FramePacketHeader(data: header.data))
        XCTAssertEqual(decoded.payloadSize, header.payloadSize)
        XCTAssertEqual(decoded.capturedAt, header.capturedAt)
        XCTAssertNil(FramePacketHeader(data: Data([0, 0, 0, 5])))
        XCTAssertNil(FramePacketHeader(data: FramePacketHeader(payloadSize: 0, capturedAt: 10).data))
        XCTAssertNil(FramePacketHeader(data: FramePacketHeader(payloadSize: 2_000_000, capturedAt: 10).data))
        XCTAssertNil(FramePacketHeader(data: FramePacketHeader(payloadSize: 10, capturedAt: .nan).data))
    }

    func testBusyEncoderDropsOldFramesAndAdmitsFreshFrameWhenReady() {
        var admission = FrameAdmission()
        XCTAssertTrue(admission.begin(at: 1))
        for index in 1...120 {
            XCTAssertFalse(admission.begin(at: 1 + Double(index) / 60))
        }
        admission.complete()
        XCTAssertTrue(admission.begin(at: 3.1))
        admission.complete()
        XCTAssertFalse(admission.begin(at: 3.15))
        XCTAssertTrue(admission.begin(at: 3.3))
        admission.complete()
        admission.setActive(false)
        XCTAssertFalse(admission.begin(at: 4))
        admission.setActive(true)
        XCTAssertTrue(admission.begin(at: 4.01))
    }

    func testDelayedAndOutOfOrderFramesCannotRollBackTheBoard() {
        var freshness = FrameFreshnessGate()
        XCTAssertTrue(freshness.accept(capturedAt: 10, now: 10.05))
        XCTAssertFalse(freshness.accept(capturedAt: 9.9, now: 10.1))
        XCTAssertFalse(freshness.accept(capturedAt: 10, now: 10.2))
        XCTAssertFalse(freshness.accept(capturedAt: 11, now: 12.1))
        XCTAssertFalse(freshness.accept(capturedAt: 13, now: 12.5))
        XCTAssertTrue(freshness.accept(capturedAt: 12.2, now: 12.5))
    }
}
