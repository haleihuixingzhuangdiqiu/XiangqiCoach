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
