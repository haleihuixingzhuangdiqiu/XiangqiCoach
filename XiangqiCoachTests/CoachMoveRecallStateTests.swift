import XCTest
@testable import XiangqiCoach

final class CoachMoveRecallStateTests: XCTestCase {
    func testSelectionOcclusionAndCandidateConfirmationKeepPublishedMoveForRecall() throws {
        var tracker = startingTracker()
        var recall = publishedRecall()
        let expected = try XCTUnwrap(previousSuggestion(recall, position: tracker.position))

        // 点选高亮暂时识别失败：丢弃候选，不丢已确认的局面与上一条走法。
        tracker.loseBoard()
        XCTAssertEqual(previousSuggestion(recall, position: tracker.position), expected)

        // 首张变化帧还不能证明落子，回看仍明确属于原局面。
        let candidate = XiangqiPosition.standard.applying(redCannonMove)
        XCTAssertEqual(tracker.observe(candidate), .confirming)
        XCTAssertEqual(previousSuggestion(recall, position: tracker.position), expected)
        XCTAssertNil(previousSuggestion(recall, position: candidate))

        // 原棋盘再次出现不清空回看，当前有效建议恢复后则优先显示当前建议。
        XCTAssertEqual(tracker.observe(.standard), .unchanged(.standard))
        recall.confirm(position: .standard, boardAtBottom: .red)
        XCTAssertEqual(previousSuggestion(recall, position: tracker.position), expected)
        XCTAssertNil(recall.previousSuggestion(for: .standard, boardAtBottom: .red, hasCurrentSuggestion: true))
    }

    func testAcceptedOneOrTwoMovesClearRecallBeforeNextAnalysis() throws {
        for next in [
            XiangqiPosition.standard.applying(redCannonMove),
            XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
        ] {
            var tracker = startingTracker()
            var recall = publishedRecall()
            _ = tracker.observe(next)
            guard case let .accepted(confirmed, _) = tracker.observe(next) else {
                return XCTFail("合法走子应在第二张画面确认")
            }
            recall.confirm(position: confirmed, boardAtBottom: .red)
            XCTAssertNil(previousSuggestion(recall, position: confirmed))
            // 不只是按当前棋盘暂时隐藏；旧摆位重现也不能复活已经用过的指引。
            XCTAssertNil(previousSuggestion(recall, position: .standard))
        }
    }

    func testConfirmedOrientationOrTurnChangePermanentlyClearsRecall() {
        var recall = publishedRecall()
        recall.confirm(position: .standard, boardAtBottom: .black)
        XCTAssertNil(previousSuggestion(recall, position: .standard))

        recall = publishedRecall()
        var sameBoardWithDifferentTurn = XiangqiPosition.standard
        sameBoardWithDifferentTurn.sideToMove = .black
        recall.confirm(position: sameBoardWithDifferentTurn, boardAtBottom: .red)
        XCTAssertNil(previousSuggestion(recall, position: .standard))
    }

    func testStopResetAndManualSyncCannotRestoreOldRecallWhenSameBoardReturns() {
        var recall = publishedRecall()
        recall.reset()
        recall.confirm(position: .standard, boardAtBottom: .red)
        XCTAssertNil(previousSuggestion(recall, position: .standard))
        XCTAssertTrue(recall.remember(redCannonMove, in: .standard, boardAtBottom: .red))
        XCTAssertNotNil(previousSuggestion(recall, position: .standard))
    }

    func testRecallRequiresOriginalPositionAndConfirmedOrientation() {
        let recall = publishedRecall()
        XCTAssertNil(previousSuggestion(recall, position: nil))
        XCTAssertNil(recall.previousSuggestion(for: .standard, boardAtBottom: nil, hasCurrentSuggestion: false))
        XCTAssertNil(recall.previousSuggestion(for: .standard, boardAtBottom: .black, hasCurrentSuggestion: false))
        XCTAssertNil(previousSuggestion(recall, position: XiangqiPosition.standard.applying(redCannonMove)))
        XCTAssertNotNil(previousSuggestion(recall, position: .standard))
    }

    func testIllegalOrOpponentsMoveCannotBecomeRecall() {
        var recall = publishedRecall()
        let illegal = XiangqiMove(from: Square(row: 9, column: 1), to: Square(row: 5, column: 2))
        XCTAssertFalse(recall.remember(illegal, in: .standard, boardAtBottom: .red))
        XCTAssertNil(previousSuggestion(recall, position: .standard))
        XCTAssertFalse(recall.remember(blackCannonMove, in: .standard, boardAtBottom: .red))
        XCTAssertFalse(recall.remember(redCannonMove, in: .standard, boardAtBottom: .black))
        XCTAssertNil(previousSuggestion(recall, position: .standard))
    }

    func testOcclusionDuringSearchDoesNotInventRecallOrRestartSameBoardWork() throws {
        var recall = CoachMoveRecallState()
        var analysis = CoachAnalysisState()
        guard case let .start(work) = analysis.request(position: .standard, now: 10) else {
            return XCTFail("首次局面应开始计算")
        }
        XCTAssertNil(previousSuggestion(recall, position: .standard))
        XCTAssertEqual(analysis.request(position: .standard, now: 10.5), .inFlight)
        let result = SearchResult(move: redCannonMove, score: 10, depth: 16,
                                  principalVariation: [redCannonMove], elapsedMilliseconds: 800, nodesVisited: 1000)
        let outcome = CoachAnalysisState.Outcome(result: result, error: nil)
        XCTAssertTrue(analysis.complete(work, outcome: outcome))
        // 遮挡时完成的结果只是缓存，尚未发布，不能提前变成“上一条走法”。
        XCTAssertNil(previousSuggestion(recall, position: .standard))
        XCTAssertEqual(analysis.request(position: .standard, now: 11), .completed(outcome))
        XCTAssertTrue(recall.remember(result.move, in: .standard, boardAtBottom: .red))
        XCTAssertNotNil(previousSuggestion(recall, position: .standard))
        XCTAssertEqual(analysis.request(position: .standard, now: 12), .completed(outcome))
    }

    private let redCannonMove = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
    private let blackCannonMove = XiangqiMove(from: Square(row: 2, column: 1), to: Square(row: 2, column: 4))

    private func startingTracker() -> BoardTracker {
        var tracker = BoardTracker()
        _ = tracker.observe(.standard)
        _ = tracker.observe(.standard)
        return tracker
    }

    private func publishedRecall() -> CoachMoveRecallState {
        var recall = CoachMoveRecallState()
        XCTAssertTrue(recall.remember(redCannonMove, in: .standard, boardAtBottom: .red))
        return recall
    }

    private func previousSuggestion(_ recall: CoachMoveRecallState, position: XiangqiPosition?) -> CoachMoveRecall? {
        recall.previousSuggestion(for: position, boardAtBottom: .red, hasCurrentSuggestion: false)
    }
}
