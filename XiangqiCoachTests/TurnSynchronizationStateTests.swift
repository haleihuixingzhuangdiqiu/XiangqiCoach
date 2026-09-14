import XCTest
@testable import XiangqiCoach

final class TurnSynchronizationStateTests: XCTestCase {
    func testClickRequiresTwoDistinctFramesCapturedAfterRequest() {
        var state = TurnSynchronizationState()
        state.request(sideToMove: .black, at: 10)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 9.9, now: 10.1))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10, now: 10.1))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.1, now: 10.2))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.1, now: 10.2))
        XCTAssertEqual(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.3, now: 10.4), .black)
    }

    func testDifferentBoardOrOrientationRestartsConfirmation() {
        var state = TurnSynchronizationState()
        state.request(sideToMove: .black, at: 10)
        let moved = XiangqiPosition.standard.applying(redCannon)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.1, now: 10.11))
        XCTAssertNil(state.observe(moved, boardAtBottom: .red, capturedAt: 10.3, now: 10.31))
        XCTAssertNil(state.observe(moved, boardAtBottom: .black, capturedAt: 10.5, now: 10.51))
        XCTAssertEqual(state.observe(moved, boardAtBottom: .black, capturedAt: 10.7, now: 10.71), .black)
    }

    func testOldOrInterruptedFramesCannotFinishConfirmation() {
        var state = TurnSynchronizationState()
        state.request(sideToMove: .red, at: 10)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.1, now: 10.2))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.3, now: 11.4))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.5, now: 11.6))
        state.recognitionInterrupted()
        XCTAssertTrue(state.isPending)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.7, now: 11.8))
        XCTAssertEqual(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.9, now: 12), .red)
    }

    func testLongGapCannotJoinTwoIndividuallyFreshFrames() {
        var state = TurnSynchronizationState()
        state.request(sideToMove: .red, at: 10)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.1, now: 10.2))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.4, now: 11.5))
        XCTAssertEqual(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.6, now: 11.7), .red)
    }

    func testStopAndReplacementRequestCannotReuseEarlierConfirmation() {
        var state = TurnSynchronizationState()
        state.request(sideToMove: .red, at: 10)
        _ = state.observe(.standard, boardAtBottom: .red, capturedAt: 10.1, now: 10.2)
        state.reset()
        XCTAssertFalse(state.isPending)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 10.3, now: 10.4))
        state.request(sideToMove: .red, at: 11)
        _ = state.observe(.standard, boardAtBottom: .red, capturedAt: 11.1, now: 11.2)
        state.request(sideToMove: .black, at: 11.3)
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.2, now: 11.4))
        XCTAssertNil(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.4, now: 11.5))
        XCTAssertEqual(state.observe(.standard, boardAtBottom: .red, capturedAt: 11.6, now: 11.7), .black)
    }

    func testUnknownMidgameCanSynchronizeAfterCoachPageClearsCandidate() throws {
        let midgame = XiangqiPosition.standard.applying(redCannon)
            .applying(XiangqiMove(from: Square(row: 2, column: 1), to: Square(row: 2, column: 4)))
            .applying(XiangqiMove(from: Square(row: 6, column: 0), to: Square(row: 5, column: 0)))
        var tracker = BoardTracker()
        _ = tracker.observe(midgame)
        XCTAssertEqual(tracker.observe(midgame), .needsSynchronization)
        tracker.loseBoard()
        var state = TurnSynchronizationState()
        state.request(sideToMove: .black, at: 10)
        // 教练页面自身无法识别为棋盘；丢失旧 candidate 不得清掉用户已登记的同步意图。
        state.recognitionInterrupted()
        XCTAssertEqual(tracker.observe(midgame), .confirming)
        XCTAssertNil(state.observe(midgame, boardAtBottom: .black, capturedAt: 10.2, now: 10.3))
        let observation = tracker.observe(midgame)
        XCTAssertEqual(observation, .needsSynchronization)
        let chosen = try XCTUnwrap(state.observe(midgame, boardAtBottom: .black, capturedAt: 10.4, now: 10.5))
        XCTAssertFalse(TurnSynchronizationState.hasProvenTurn(for: observation, history: tracker.analysisHistory))
        XCTAssertEqual(tracker.synchronize(sideToMove: chosen), .accepted(midgame, .manualSynchronization))
        state.reset()
        XCTAssertFalse(state.isPending)
        XCTAssertEqual(tracker.position?.sideToMove, .black)
    }

    func testFirstBlackViewH2E2KeepsProvenBlackTurnAndMoveHistory() throws {
        var tracker = BoardTracker()
        var state = TurnSynchronizationState()
        state.request(sideToMove: .red, at: 10)
        let moved = XiangqiPosition.standard.applying(redCannon)
        XCTAssertEqual(redCannon.iccs(), "h2e2")
        _ = tracker.observe(moved)
        XCTAssertNil(state.observe(moved, boardAtBottom: .black, capturedAt: 10.1, now: 10.2))
        let observation = tracker.observe(moved)
        XCTAssertEqual(state.observe(moved, boardAtBottom: .black, capturedAt: 10.3, now: 10.4), .red)
        XCTAssertTrue(TurnSynchronizationState.hasProvenTurn(for: observation, history: tracker.analysisHistory))
        XCTAssertEqual(tracker.position?.sideToMove, .black)
        XCTAssertEqual(tracker.analysisHistory?.moves, [redCannon])
        // 若点击前排队帧已先证明了此局面，后续 unchanged 也不能被旧红方选择覆盖。
        XCTAssertTrue(TurnSynchronizationState.hasProvenTurn(for: tracker.observe(moved), history: tracker.analysisHistory))
    }

    func testStandardAlwaysKeepsRedButManualMidgameCanBeCorrected() {
        var tracker = BoardTracker()
        var input = XiangqiPosition.standard
        input.sideToMove = .black
        _ = tracker.observe(input)
        let opening = tracker.observe(input)
        XCTAssertTrue(TurnSynchronizationState.hasProvenTurn(for: opening, history: tracker.analysisHistory))
        XCTAssertEqual(tracker.position?.sideToMove, .red)
        let manuallyAnchored = XiangqiPosition.standard.applying(redCannon)
        let history = AnalysisHistory(root: manuallyAnchored, moves: [])
        XCTAssertFalse(TurnSynchronizationState.hasProvenTurn(for: .unchanged(manuallyAnchored), history: history))
    }

    private var redCannon: XiangqiMove {
        XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
    }
}
