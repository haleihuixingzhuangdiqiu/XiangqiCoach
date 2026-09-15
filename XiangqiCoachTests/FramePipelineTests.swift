import AVFoundation
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

    func testTransportCompletionImmediatelyTakesLatestCaptureWithoutAnotherOffer() throws {
        var admission = FrameAdmission<Int>()
        let generation = try XCTUnwrap(admission.offer(0, capturedAt: 1))
        guard case let .frame(first) = admission.next(generation: generation, at: 1) else { return XCTFail("首帧应立即编码") }
        XCTAssertEqual(first.payload, 0)
        // 模拟连接阻塞期间 120 张新截图；只唤醒一次任务，旧截图不断被替换。
        for index in 1...120 {
            XCTAssertNil(admission.offer(index, capturedAt: 1 + Double(index) / 60))
        }
        guard case let .frame(latest) = admission.next(generation: generation, at: 3) else { return XCTFail("连接恢复应立即取最新帧") }
        XCTAssertEqual(latest.payload, 120)
        XCTAssertEqual(latest.capturedAt, 3)
        guard case .idle = admission.next(generation: generation, at: 3.01) else { return XCTFail("不能继续排队发送中间 119 帧") }
    }

    func testEncodingIntervalRetainsLatestFrameWithinConfiguredRate() throws {
        var admission = FrameAdmission<Int>()
        let generation = try XCTUnwrap(admission.offer(0, capturedAt: 1))
        guard case .frame = admission.next(generation: generation, at: 1) else { return XCTFail("首帧应立即编码") }
        XCTAssertNil(admission.offer(1, capturedAt: 1.01))
        guard case let .wait(delay) = admission.next(generation: generation, at: 1.01) else { return XCTFail("应遵守 10 fps 编码上限") }
        XCTAssertEqual(delay, FrameAdmission<Int>.minimumInterval - 0.01, accuracy: 0.000_001)
        XCTAssertNil(admission.offer(2, capturedAt: 1.1))
        guard case let .frame(latest) = admission.next(generation: generation, at: 1 + FrameAdmission<Int>.minimumInterval) else {
            return XCTFail("限频到期后应消费等待期间最新截图")
        }
        XCTAssertEqual(latest.payload, 2)
    }

    func testPauseInvalidatesPendingCaptureAndOldCompletionCannotConsumeResumedFrame() throws {
        var admission = FrameAdmission<Int>()
        let oldGeneration = try XCTUnwrap(admission.offer(0, capturedAt: 1))
        guard case .frame = admission.next(generation: oldGeneration, at: 1) else { return XCTFail("首帧应立即编码") }
        XCTAssertNil(admission.offer(1, capturedAt: 1.01))
        admission.setActive(false)
        XCTAssertNil(admission.offer(2, capturedAt: 1.02))
        admission.setActive(true)
        let newGeneration = try XCTUnwrap(admission.offer(3, capturedAt: 1.03))
        guard case .idle = admission.next(generation: oldGeneration, at: 1.04) else { return XCTFail("暂停前的回调必须失效") }
        guard case let .frame(resumed) = admission.next(generation: newGeneration, at: 1.04) else { return XCTFail("恢复后不等待旧编码间隔") }
        XCTAssertEqual(resumed.payload, 3)
        XCTAssertEqual(resumed.generation, newGeneration)
    }

    func testExpiredPendingCaptureIsDroppedBeforeEncoding() throws {
        var admission = FrameAdmission<Int>()
        let generation = try XCTUnwrap(admission.offer(0, capturedAt: 1))
        guard case .idle = admission.next(generation: generation, at: 1.5) else { return XCTFail("过期截图不能消耗编码和传输时间") }
        XCTAssertNotNil(admission.offer(1, capturedAt: 1.51))
        guard case let .frame(fresh) = admission.next(generation: generation, at: 1.51) else { return XCTFail("过期任务不能堵住新截图") }
        XCTAssertEqual(fresh.payload, 1)
    }

    @MainActor
    func testCongestedOverlayReplacesOldSamplesWithLatestStateImmediately() throws {
        let factory = OverlayFrameFactory()
        let destination = BufferedOverlayDestination()
        var state = CoachOverlayState()
        for index in 0..<4 {
            state.move = "状态 \(index)"
            factory.displayLatest(state: state, on: destination)
        }
        XCTAssertEqual(destination.samples.count, 1, "显示队列只能保留最新样本")
        XCTAssertEqual(destination.maximumQueueLength, 1)
        let expected = try XCTUnwrap(factory.makeSampleBuffer(state: state))
        let displayed = try XCTUnwrap(destination.samples.last)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(displayed) === CMSampleBufferGetImageBuffer(expected),
                      "背压消除后无需等待保活定时器，最后一次更新已经入队")
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(displayed, createIfNecessary: false) as? [[String: Any]])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool, true)
    }

    func testDelayedAndOutOfOrderFramesCannotRollBackTheBoard() {
        var freshness = FrameFreshnessGate()
        XCTAssertTrue(freshness.accept(capturedAt: 10, now: 10.05))
        XCTAssertFalse(freshness.accept(capturedAt: 9.9, now: 10.1))
        XCTAssertFalse(freshness.accept(capturedAt: 10, now: 10.2))
        XCTAssertFalse(freshness.accept(capturedAt: 11, now: 12.1))
        XCTAssertFalse(freshness.accept(capturedAt: 13, now: 12.5))
        // 预检本身不能推进已接受时间戳，坏 JPEG 之后仍可接收真正有效的帧。
        XCTAssertTrue(freshness.isAcceptable(capturedAt: 12.4, now: 12.5))
        XCTAssertTrue(freshness.accept(capturedAt: 12.2, now: 12.5))
    }
}

/// 模拟显示端暂停消费：只要生产端没主动丢旧样本，队列长度就会持续增长。
private final class BufferedOverlayDestination: OverlayFrameDestination {
    var status: AVQueuedSampleBufferRenderingStatus { .rendering }
    var isReadyForMoreMediaData: Bool { samples.isEmpty }
    private(set) var samples: [CMSampleBuffer] = []
    private(set) var maximumQueueLength = 0

    func flush() { samples.removeAll() }
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        samples.append(sampleBuffer)
        maximumQueueLength = max(maximumQueueLength, samples.count)
    }
}
