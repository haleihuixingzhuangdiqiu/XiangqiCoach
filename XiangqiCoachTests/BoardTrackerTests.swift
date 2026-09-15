import XCTest
@testable import XiangqiCoach

final class BoardTrackerTests: XCTestCase {
    func testLegalReturnToStartingBoardPreservesRepetitionHistory() throws {
        var tracker = startingTracker()
        let moves = [
            XiangqiMove(from: Square(row: 9, column: 1), to: Square(row: 7, column: 2)),
            XiangqiMove(from: Square(row: 0, column: 1), to: Square(row: 2, column: 2)),
            XiangqiMove(from: Square(row: 7, column: 2), to: Square(row: 9, column: 1)),
            XiangqiMove(from: Square(row: 2, column: 2), to: Square(row: 0, column: 1))
        ]
        var position = XiangqiPosition.standard
        for move in moves {
            XCTAssertTrue(position.legalMoves().contains(move))
            position = position.applying(move)
            _ = tracker.observe(position)
            XCTAssertEqual(tracker.observe(position), .accepted(position, .legalMoves(1)))
        }
        XCTAssertEqual(tracker.position, .standard)
        XCTAssertEqual(tracker.analysisHistory?.moves, moves)
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

    func testMarkerAnchorAndRestartResetUnprovableHistory() throws {
        var tracker = startingTracker()
        let next = midgame
        let evidence = BoardMoveEvidence(move: redPawnMove, movedSide: .red)
        _ = tracker.observe(next, lastMove: evidence)
        XCTAssertEqual(tracker.observe(next, lastMove: evidence), .accepted(next, .lastMoveMarker))
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
        XCTAssertEqual(tracker.observe(image, lastMove: BoardMoveEvidence(move: blackCannonMove, movedSide: .black)), .unchanged(.standard))
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
        let previousBlackMove = BoardMoveEvidence(
            move: XiangqiMove(from: Square(row: 8, column: 3), to: Square(row: 8, column: 2)), movedSide: .black
        )
        _ = tracker.observe(initial, lastMove: previousBlackMove)
        XCTAssertEqual(tracker.observe(initial, lastMove: previousBlackMove), .accepted(initial, .lastMoveMarker))
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
        for _ in 0..<5 { XCTAssertEqual(tracker.observe(wrong), .waitingForMoveEvidence) }
        XCTAssertEqual(tracker.position, .standard)
    }

    func testIllegalTeleportIsRejectedEvenWhenOnlyTwoSquaresChanged() {
        var tracker = startingTracker()
        let impossible = XiangqiPosition.standard.applying(XiangqiMove(from: Square(row: 9, column: 1), to: Square(row: 5, column: 2)))
        _ = tracker.observe(impossible)
        XCTAssertEqual(tracker.observe(impossible), .waitingForMoveEvidence)
        XCTAssertEqual(tracker.position, .standard)
    }

    func testUnknownMidgameWaitsForTwoNewMatchingMarkerFrames() {
        var tracker = BoardTracker()
        let next = midgame
        _ = tracker.observe(next)
        XCTAssertEqual(tracker.observe(next), .waitingForMoveEvidence)
        XCTAssertNil(tracker.position)
        let evidence = BoardMoveEvidence(move: redPawnMove, movedSide: .red)
        XCTAssertEqual(tracker.observe(next, lastMove: evidence), .waitingForMoveEvidence)
        XCTAssertNil(tracker.position)
        var mislabeled = next
        mislabeled.sideToMove = .red
        XCTAssertEqual(tracker.observe(mislabeled, lastMove: evidence), .accepted(next, .lastMoveMarker))
    }

    func testBriefOcclusionPreservesAnchorAndResumesIdenticalBoard() {
        var tracker = startingTracker()
        tracker.loseBoard()
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

    func testRestartClearsPriorAnchorAndUnstableEvidence() {
        var tracker = startingTracker()
        tracker.reset()
        XCTAssertNil(tracker.position)
        var standard = XiangqiPosition.standard
        standard.sideToMove = .black
        _ = tracker.observe(standard)
        XCTAssertEqual(tracker.observe(standard), .accepted(.standard, .newGame))
    }

    func testMarkerChangesMissingFramesAndBoardChangesResetEvidenceCount() {
        var tracker = BoardTracker()
        let first = BoardMoveEvidence(move: redPawnMove, movedSide: .red)
        let other = BoardMoveEvidence(move: redCannonMove, movedSide: .red)
        XCTAssertEqual(tracker.observe(midgame, lastMove: first), .confirming)
        XCTAssertEqual(tracker.observe(midgame, lastMove: other), .waitingForMoveEvidence)
        XCTAssertEqual(tracker.observe(midgame), .waitingForMoveEvidence)
        XCTAssertEqual(tracker.observe(midgame, lastMove: first), .waitingForMoveEvidence)
        let next = midgame.applying(blackPawnMove)
        XCTAssertEqual(tracker.observe(next, lastMove: first), .confirming)
        XCTAssertEqual(tracker.observe(midgame, lastMove: first), .confirming)
        XCTAssertEqual(tracker.observe(midgame, lastMove: first), .accepted(midgame, .lastMoveMarker))
    }

    func testOcclusionRequiresTwoFreshMarkerFramesButPreservesKnownBoard() {
        var tracker = BoardTracker()
        let evidence = BoardMoveEvidence(move: redPawnMove, movedSide: .red)
        XCTAssertEqual(tracker.observe(midgame, lastMove: evidence), .confirming)
        tracker.loseBoard()
        XCTAssertEqual(tracker.observe(midgame, lastMove: evidence), .confirming)
        XCTAssertNil(tracker.position)
        XCTAssertEqual(tracker.observe(midgame, lastMove: evidence), .accepted(midgame, .lastMoveMarker))
        let history = tracker.analysisHistory
        tracker.loseBoard()
        XCTAssertEqual(tracker.observe(midgame), .unchanged(midgame))
        XCTAssertEqual(tracker.analysisHistory, history)
    }

    func testLegalChainAndSameBoardIgnoreStaleMarkersThatWouldReverseTurn() {
        var tracker = startingTracker()
        let afterTwo = XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
        let staleRedMarker = BoardMoveEvidence(move: redCannonMove, movedSide: .red)
        _ = tracker.observe(afterTwo, lastMove: staleRedMarker)
        XCTAssertEqual(tracker.observe(afterTwo, lastMove: staleRedMarker), .accepted(afterTwo, .legalMoves(2)))
        XCTAssertEqual(tracker.position?.sideToMove, .red)
        var wrongInputTurn = afterTwo
        wrongInputTurn.sideToMove = .black
        for _ in 0..<3 {
            XCTAssertEqual(tracker.observe(wrongInputTurn, lastMove: staleRedMarker), .unchanged(afterTwo))
        }
        XCTAssertEqual(tracker.analysisHistory?.moves, [redCannonMove, blackCannonMove])
    }

    func testConfirmedOldMarkerCannotAnchorAChangedUnknownBoard() {
        var tracker = startingTracker()
        let afterTwo = XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove)
        _ = tracker.observe(afterTwo)
        _ = tracker.observe(afterTwo)
        let lastRedMove = XiangqiMove(from: Square(row: 6, column: 2), to: Square(row: 5, column: 2))
        let afterFive = afterTwo.applying(redPawnMove).applying(blackPawnMove).applying(lastRedMove)
        let stale = BoardMoveEvidence(move: blackCannonMove, movedSide: .black)
        tracker.loseBoard()
        _ = tracker.observe(afterFive, lastMove: stale)
        for _ in 0..<3 { XCTAssertEqual(tracker.observe(afterFive, lastMove: stale), .waitingForMoveEvidence) }
        XCTAssertEqual(tracker.position, afterTwo)
        let current = BoardMoveEvidence(move: lastRedMove, movedSide: .red)
        XCTAssertEqual(tracker.observe(afterFive, lastMove: current), .waitingForMoveEvidence)
        XCTAssertEqual(tracker.observe(afterFive, lastMove: current), .accepted(afterFive, .lastMoveMarker))
        XCTAssertEqual(tracker.analysisHistory, AnalysisHistory(root: afterFive, moves: []))
    }

    func testWrongColorOccupiedOriginEmptyDestinationAndIllegalGeometryAreRejected() {
        let invalid = [
            BoardMoveEvidence(move: redPawnMove, movedSide: .black),
            BoardMoveEvidence(move: XiangqiMove(from: Square(row: 6, column: 2), to: redPawnMove.to), movedSide: .red),
            BoardMoveEvidence(move: XiangqiMove(from: redPawnMove.from, to: Square(row: 5, column: 1)), movedSide: .red),
            BoardMoveEvidence(move: XiangqiMove(from: Square(row: 4, column: 0), to: redPawnMove.to), movedSide: .red),
            BoardMoveEvidence(move: XiangqiMove(from: Square(row: -1, column: 0), to: redPawnMove.to), movedSide: .red),
            BoardMoveEvidence(move: XiangqiMove(from: redPawnMove.to, to: redPawnMove.to), movedSide: .red)
        ]
        for evidence in invalid {
            var tracker = BoardTracker()
            _ = tracker.observe(midgame, lastMove: evidence)
            XCTAssertEqual(tracker.observe(midgame, lastMove: evidence), .waitingForMoveEvidence)
            XCTAssertNil(tracker.position)
        }
    }

    func testCannonCaptureCanAnchorWithoutInventingCapturedPieceHistory() throws {
        var observed = try minimalPosition()
        let move = XiangqiMove(from: Square(row: 7, column: 0), to: Square(row: 3, column: 0))
        observed[move.to] = Piece(side: .red, kind: .cannon)
        observed[Square(row: 5, column: 0)] = Piece(side: .red, kind: .pawn)
        observed.sideToMove = .black
        let evidence = BoardMoveEvidence(move: move, movedSide: .red)
        var tracker = BoardTracker()
        _ = tracker.observe(observed, lastMove: evidence)
        XCTAssertEqual(tracker.observe(observed, lastMove: evidence), .accepted(observed, .lastMoveMarker))
        XCTAssertEqual(tracker.analysisHistory, AnalysisHistory(root: observed, moves: []))

        // 两个炮架即使补回被吃子也不能成立。
        observed[Square(row: 4, column: 0)] = Piece(side: .black, kind: .pawn)
        tracker.reset()
        _ = tracker.observe(observed, lastMove: evidence)
        XCTAssertEqual(tracker.observe(observed, lastMove: evidence), .waitingForMoveEvidence)
    }

    func testCannonCaptureCannotInventMoreThanOpponentStartingMaterial() {
        var observed = XiangqiPosition.standard
        observed[Square(row: 7, column: 7)] = nil
        observed[Square(row: 4, column: 0)] = Piece(side: .red, kind: .cannon)
        let evidence = BoardMoveEvidence(
            move: XiangqiMove(from: Square(row: 7, column: 0), to: Square(row: 4, column: 0)), movedSide: .red
        )
        var tracker = BoardTracker()
        _ = tracker.observe(observed, lastMove: evidence)
        XCTAssertEqual(tracker.observe(observed, lastMove: evidence), .waitingForMoveEvidence)
        XCTAssertNil(tracker.position)
    }

    func testBlockedHorseAndMoveLeavingOwnKingInCheckAreRejected() throws {
        var horseBoard = try minimalPosition()
        let horse = XiangqiMove(from: Square(row: 7, column: 1), to: Square(row: 5, column: 2))
        horseBoard[horse.to] = Piece(side: .red, kind: .horse)
        horseBoard[Square(row: 6, column: 1)] = Piece(side: .red, kind: .rook)
        var tracker = BoardTracker()
        let evidence = BoardMoveEvidence(move: horse, movedSide: .red)
        _ = tracker.observe(horseBoard, lastMove: evidence)
        XCTAssertEqual(tracker.observe(horseBoard, lastMove: evidence), .waitingForMoveEvidence)

        let checked = try XCTUnwrap(XiangqiPosition(fen: "4k4/9/9/9/4p4/9/9/1R7/9/r3K4 b"))
        let unrelated = BoardMoveEvidence(
            move: XiangqiMove(from: Square(row: 7, column: 0), to: Square(row: 7, column: 1)), movedSide: .red
        )
        tracker.reset()
        _ = tracker.observe(checked, lastMove: unrelated)
        XCTAssertEqual(tracker.observe(checked, lastMove: unrelated), .waitingForMoveEvidence)
    }

    func testNewMarkerAnchorClearsRecallAndStartsHistoryAtObservedPosition() {
        var tracker = startingTracker()
        var recall = CoachMoveRecallState()
        recall.remember(redCannonMove, in: .standard, boardAtBottom: .red)
        let evidence = BoardMoveEvidence(move: redPawnMove, movedSide: .red)
        _ = tracker.observe(midgame, lastMove: evidence)
        guard case let .accepted(position, reason) = tracker.observe(midgame, lastMove: evidence) else {
            return XCTFail("可信标记应自动建立新锚点")
        }
        XCTAssertEqual(reason, .lastMoveMarker)
        recall.confirm(position: position, boardAtBottom: .red)
        XCTAssertNil(recall.previousSuggestion(for: .standard, boardAtBottom: .red, hasCurrentSuggestion: false))
        XCTAssertEqual(tracker.analysisHistory, AnalysisHistory(root: position, moves: []))
    }

    private var midgame: XiangqiPosition {
        XiangqiPosition.standard.applying(redCannonMove).applying(blackCannonMove).applying(redPawnMove)
    }

    private func minimalPosition() throws -> XiangqiPosition {
        try XCTUnwrap(XiangqiPosition(fen: "4k4/9/9/9/4p4/9/9/9/9/4K4 r"))
    }

    private let redPawnMove = XiangqiMove(from: Square(row: 6, column: 0), to: Square(row: 5, column: 0))
    private let blackPawnMove = XiangqiMove(from: Square(row: 3, column: 0), to: Square(row: 4, column: 0))

    private let redCannonMove = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
    private let blackCannonMove = XiangqiMove(from: Square(row: 2, column: 1), to: Square(row: 2, column: 4))

    private func startingTracker() -> BoardTracker {
        var tracker = BoardTracker()
        _ = tracker.observe(.standard)
        _ = tracker.observe(.standard)
        return tracker
    }
}
