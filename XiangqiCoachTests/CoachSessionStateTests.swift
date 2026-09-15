import XCTest
@testable import XiangqiCoach

final class CoachSessionStateTests: XCTestCase {
    func testRecordingStartsWithoutWaitingForRecognition() {
        var state = CoachSessionState()
        XCTAssertEqual(state.phase, .notRecording)
        state.setRecognizerReady(true)
        state.setCaptureActive(true)
        XCTAssertEqual(state.phase, .waitingForFrame)
        XCTAssertTrue(state.receiveFrame())
        XCTAssertEqual(state.phase, .waitingForBoard)
    }

    func testReceivedFramesWhilePreparingTemplatesShowPreparationStep() {
        var state = CoachSessionState()
        state.setCaptureActive(true)
        state.receiveFrame()
        XCTAssertTrue(state.hasReceivedFrame)
        XCTAssertEqual(state.phase, .preparingRecognition)
        XCTAssertFalse(state.advance(to: .analyzing, generation: state.generation))
        state.setRecognizerReady(true)
        XCTAssertEqual(state.phase, .waitingForBoard)
    }

    func testRecordingAndRecognitionLifecycle() {
        var state = readyRecording()
        for phase: CoachSessionState.Phase in [.confirmingBoard, .analyzing, .recommendation, .waitingForBoard, .confirmingBoard, .finished] {
            XCTAssertTrue(state.advance(to: phase, generation: state.generation))
            XCTAssertEqual(state.phase, phase)
        }
        state.setCaptureActive(false)
        XCTAssertEqual(state.phase, .recordingStopped)
    }

    func testRepeatedFramesDoNotClearRecommendation() {
        var state = readyRecording()
        state.advance(to: .recommendation, generation: state.generation)
        state.receiveFrame()
        state.setCaptureActive(true)
        XCTAssertEqual(state.phase, .recommendation)
    }

    func testStoppingRejectsLateFramesAndAnalysisResults() {
        var state = readyRecording()
        let generation = state.generation
        state.advance(to: .analyzing, generation: generation)
        state.setCaptureActive(false)
        XCTAssertFalse(state.receiveFrame())
        XCTAssertFalse(state.acceptsResult(from: generation))
        XCTAssertFalse(state.advance(to: .recommendation, generation: generation))
        XCTAssertEqual(state.phase, .recordingStopped)
    }

    func testRestartRejectsPriorRecordingResultsAndWaitsForNewFrame() {
        var state = readyRecording()
        let generation = state.generation
        state.setCaptureActive(false)
        state.setCaptureActive(true)
        XCTAssertEqual(state.phase, .waitingForFrame)
        XCTAssertFalse(state.hasReceivedFrame)
        XCTAssertFalse(state.advance(to: .recommendation, generation: generation))
        state.receiveFrame()
        XCTAssertEqual(state.phase, .waitingForBoard)
    }

    func testSwitchingTemplatesInvalidatesPriorRecognitionWithoutStoppingRecording() {
        var state = readyRecording()
        let generation = state.generation
        state.setRecognizerReady(false)
        XCTAssertTrue(state.isCapturing)
        XCTAssertTrue(state.hasReceivedFrame)
        XCTAssertEqual(state.phase, .preparingRecognition)
        state.setRecognizerReady(true)
        XCTAssertFalse(state.acceptsResult(from: generation))
        XCTAssertFalse(state.advance(to: .recommendation, generation: generation))
        XCTAssertEqual(state.phase, .waitingForBoard)
    }

    func testTemplateFailureShowsExplicitErrorWhileFramesKeepArriving() {
        var state = CoachSessionState()
        state.setCaptureActive(true)
        state.setPreparationFailed()
        state.receiveFrame()
        XCTAssertEqual(state.phase, .recognitionUnavailable)
        XCTAssertTrue(state.hasReceivedFrame)
        XCTAssertFalse(state.advance(to: .analyzing, generation: state.generation))
        state.setRecognizerReady(false)
        XCTAssertEqual(state.phase, .preparingRecognition)
        state.setRecognizerReady(true)
        XCTAssertEqual(state.phase, .waitingForBoard)
    }

    func testPreparingTemplatesAfterStopDoesNotRestartRecording() {
        var state = readyRecording()
        state.setCaptureActive(false)
        state.setRecognizerReady(false)
        state.setRecognizerReady(true)
        XCTAssertEqual(state.phase, .recordingStopped)
        XCTAssertFalse(state.isCapturing)
    }

    private func readyRecording() -> CoachSessionState {
        var state = CoachSessionState()
        state.setRecognizerReady(true)
        state.setCaptureActive(true)
        state.receiveFrame()
        return state
    }
}

final class CoachBroadcastConnectionStateTests: XCTestCase {
    func testSystemRecordingWithoutAnyExtensionFrameCannotResumeGuidance() {
        let state = CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: nil, now: 100)
        XCTAssertEqual(state, .waitingForFrames)
        XCTAssertFalse(state.canResumeGuidance)
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: nil, now: 200), .waitingForFrames)
    }

    func testShortFrameInterruptionRetainsConnectionThroughThreeSeconds() {
        for age in [0.0, 0.5, 1.5, 3.0] {
            let state = CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: 10, now: 10 + age)
            XCTAssertEqual(state, .receiving)
            XCTAssertTrue(state.canResumeGuidance)
        }
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: 10, now: 13.001), .interrupted)
    }

    func testInterruptedConnectionRecoversOnlyWhenLatestExtensionFrameArrives() {
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: 10, now: 20), .interrupted)
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: 10, now: 21), .interrupted)
        let recovered = CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: 21, now: 21.05)
        XCTAssertEqual(recovered, .receiving)
        XCTAssertTrue(recovered.canResumeGuidance)
    }

    func testInvalidOrFutureTimesNeverClaimConnection() {
        let samples: [(Double, Double)] = [
            (.nan, 10), (.infinity, 10), (-.infinity, 10), (-1, 0),
            (10, .nan), (10, .infinity), (10, -.infinity), (0, -1), (11, 10)
        ]
        for (last, now) in samples {
            let state = CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: last, now: now)
            XCTAssertEqual(state, .interrupted)
            XCTAssertFalse(state.canResumeGuidance)
        }
    }

    func testStopOverridesRecentFramesAndNewSessionWaitsAfterCallerClearsTimestamp() {
        var lastFrameAt: Double? = 10
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: lastFrameAt, now: 10.1), .receiving)
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: false, lastFrameAt: lastFrameAt, now: 10.2), .stopped)
        // 纯投影不记住先前调用；会话所有者必须丢掉上次录屏的时间戳，不能以旧帧替代新连接。
        lastFrameAt = nil
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: lastFrameAt, now: 10.3), .waitingForFrames)
        lastFrameAt = 10.4
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: true, lastFrameAt: lastFrameAt, now: 10.5), .receiving)
    }

    func testOnlyReceivingAllowsResumeAndStoppedIgnoresInvalidTimestamp() {
        for state: CoachBroadcastConnectionState in [.stopped, .waitingForFrames, .interrupted] {
            XCTAssertFalse(state.canResumeGuidance)
        }
        XCTAssertTrue(CoachBroadcastConnectionState.receiving.canResumeGuidance)
        XCTAssertEqual(CoachBroadcastConnectionState.evaluate(isCaptured: false, lastFrameAt: .nan, now: .nan), .stopped)
    }
}
