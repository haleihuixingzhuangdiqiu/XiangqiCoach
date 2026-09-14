import XCTest
@testable import XiangqiCoach

final class BoardTrackerTests: XCTestCase {
    func testLegalReturnToStartingBoardPreservesRepetitionHistory() throws {
        var tracker = startingTracker()
        let encodedMoves = ["b0c2", "b9c7", "c2b0", "c7b9"]
        var position = XiangqiPosition.standard
        for encoded in encodedMoves {
            let move = try XCTUnwrap(XiangqiEngine.move(fromICCS: encoded))
            XCTAssertTrue(position.legalMoves().contains(move))
            position = position.applying(move)
            _ = tracker.observe(position)
            XCTAssertEqual(tracker.observe(position), .accepted(position, .legalMoves(1)))
        }
        XCTAssertEqual(tracker.position, .standard)
        XCTAssertEqual(tracker.analysisHistory?.moves.map { $0.iccs() }, encodedMoves)
    }

    func testSearchHistoryRetainsProvenMovesAcrossOcclusionAndTwoMoveCatchUp() throws {
        var tracker = startingTracker()
        let afterTwo = XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
        _ = tracker.observe(afterTwo)
        _ = tracker.observe(afterTwo)
        tracker.loseBoard()
        _ = tracker.observe(afterTwo)
        let pawnMove = XiangqiMove(from: Square(row: 6, column: 0), to: Square(row: 5, column: 0))
        let afterThree = afterTwo.applying(pawnMove)
        _ = tracker.observe(afterThree)
        _ = tracker.observe(afterThree)
        let history = try XCTUnwrap(tracker.analysisHistory)
        XCTAssertEqual(history.root, .standard)
        XCTAssertEqual(history.moves, [redCannonMove, blackCannonMove, pawnMove])
        XCTAssertEqual(history.moves.reduce(history.root) { $0.applying($1) }, tracker.position)
    }

    func testManualSynchronizationAndRestartResetUnprovableHistory() throws {
        var tracker = startingTracker()
        let next = XiangqiPosition.standard.applying(redCannonMove)
        _ = tracker.observe(next)
        _ = tracker.observe(next)
        _ = tracker.synchronize(sideToMove: .black)
        XCTAssertEqual(tracker.analysisHistory, AnalysisHistory(root: next, moves: []))
        tracker.reset()
        XCTAssertNil(tracker.analysisHistory)
        _ = tracker.observe(.standard)
        _ = tracker.observe(.standard)
        XCTAssertEqual(tracker.analysisHistory, AnalysisHistory(root: .standard, moves: []))
    }

    func testStartingPositionAlwaysUsesRedTurn() {
        var tracker = BoardTracker()
        var image = XiangqiPosition.standard
        image.sideToMove = .black
        XCTAssertEqual(tracker.observe(image), .confirming)
        XCTAssertEqual(tracker.observe(image), .accepted(.standard, .newGame))
        XCTAssertEqual(tracker.synchronize(sideToMove: .black), .accepted(.standard, .manualSynchronization))
    }

    func testSingleLegalMoveProvesOpponentTurn() {
        var tracker = startingTracker()
        let next = XiangqiPosition.standard.applying(redCannonMove)
        XCTAssertEqual(tracker.observe(next), .confirming)
        XCTAssertEqual(tracker.observe(next), .accepted(next, .legalMoves(1)))
        var mislabeled = next
        mislabeled.sideToMove = .red
        XCTAssertEqual(tracker.observe(mislabeled), .unchanged(next))
    }

    func testTwoLegalMovesCatchUpWithoutGuessingTurn() {
        var tracker = startingTracker()
        let next = XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
        XCTAssertEqual(tracker.observe(next), .confirming)
        XCTAssertEqual(tracker.observe(next), .accepted(next, .legalMoves(2)))
        XCTAssertEqual(tracker.position?.sideToMove, .red)
    }

    func testTwoMoveCaptureAndRecaptureCanBeProvenFromOnlyTwoChangedSquares() throws {
        var tracker = BoardTracker()
        let initial = try XCTUnwrap(XiangqiPosition(fen: "4k4/9/9/9/4p4/9/9/9/r1r6/R3K4 r"))
        _ = tracker.observe(initial)
        _ = tracker.observe(initial)
        _ = tracker.synchronize(sideToMove: .red)
        let capture = XiangqiMove(from: Square(row: 9, column: 0), to: Square(row: 8, column: 0))
        let recapture = XiangqiMove(from: Square(row: 8, column: 2), to: Square(row: 8, column: 0))
        let next = initial.applying(capture).applying(recapture)
        XCTAssertEqual(initial.changedSquares(comparedWith: next).count, 2)
        _ = tracker.observe(next)
        XCTAssertEqual(tracker.observe(next), .accepted(next, .legalMoves(2)))
    }

    func testStartingAfterComputersFirstMoveUsesProvenBlackTurn() {
        var tracker = BoardTracker()
        let next = XiangqiPosition.standard.applying(redCannonMove)
        _ = tracker.observe(next)
        XCTAssertEqual(tracker.observe(next), .accepted(next, .legalMoves(1)))
    }

    func testWrongSideMoveIsNeverAcceptedBySmallChangedSquareCount() {
        var tracker = startingTracker()
        let wrong = XiangqiPosition.standard.applying(blackCannonMove)
        _ = tracker.observe(wrong)
        for _ in 0..<5 { XCTAssertEqual(tracker.observe(wrong), .needsSynchronization) }
        XCTAssertEqual(tracker.position, .standard)
    }

    func testIllegalTeleportIsRejectedEvenWhenOnlyTwoSquaresChanged() {
        var tracker = startingTracker()
        let impossible = XiangqiPosition.standard.applying(XiangqiMove(from: Square(row: 9, column: 1), to: Square(row: 5, column: 2)))
        _ = tracker.observe(impossible)
        XCTAssertEqual(tracker.observe(impossible), .needsSynchronization)
        XCTAssertEqual(tracker.position, .standard)
    }

    func testUnknownMidgameRequiresExplicitSynchronizationOfLatestBoard() {
        var tracker = BoardTracker()
        let next = XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
            .applying(XiangqiMove(from: Square(row: 6, column: 0), to: Square(row: 5, column: 0)))
        _ = tracker.observe(next)
        XCTAssertEqual(tracker.observe(next), .needsSynchronization)
        XCTAssertNil(tracker.position)
        XCTAssertEqual(tracker.synchronize(sideToMove: .black), .accepted(next, .manualSynchronization))
    }

    func testBriefOcclusionPreservesAnchorAndResumesIdenticalBoard() {
        var tracker = startingTracker()
        tracker.loseBoard()
        XCTAssertEqual(tracker.synchronize(sideToMove: .black), .confirming)
        XCTAssertEqual(tracker.observe(.standard), .unchanged(.standard))
        let next = XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
        _ = tracker.observe(next)
        XCTAssertEqual(tracker.observe(next), .accepted(next, .legalMoves(2)))
    }

    func testTransientWrongBoardDoesNotReplaceAnchor() {
        var tracker = startingTracker()
        let transient = XiangqiPosition.standard.applying(blackCannonMove)
        XCTAssertEqual(tracker.observe(transient), .confirming)
        for _ in 0..<5 { XCTAssertEqual(tracker.observe(.standard), .unchanged(.standard)) }
        XCTAssertEqual(tracker.position, .standard)
    }

    func testNewGameAfterBlackTurnRestartsWithRedTurn() {
        var tracker = startingTracker()
        let next = XiangqiPosition.standard.applying(redCannonMove)
        _ = tracker.observe(next)
        _ = tracker.observe(next)
        XCTAssertEqual(tracker.position?.sideToMove, .black)
        _ = tracker.observe(.standard)
        XCTAssertEqual(tracker.observe(.standard), .accepted(.standard, .newGame))
    }

    func testRestartClearsPriorAnchorAndUnstableSynchronization() {
        var tracker = startingTracker()
        tracker.reset()
        XCTAssertNil(tracker.position)
        XCTAssertEqual(tracker.synchronize(sideToMove: .black), .confirming)
        var standard = XiangqiPosition.standard
        standard.sideToMove = .black
        _ = tracker.observe(standard)
        XCTAssertEqual(tracker.observe(standard), .accepted(.standard, .newGame))
    }

    private let redCannonMove = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
    private let blackCannonMove = XiangqiMove(from: Square(row: 2, column: 1), to: Square(row: 2, column: 4))

    private func startingTracker() -> BoardTracker {
        var tracker = BoardTracker()
        _ = tracker.observe(.standard)
        _ = tracker.observe(.standard)
        return tracker
    }
}
