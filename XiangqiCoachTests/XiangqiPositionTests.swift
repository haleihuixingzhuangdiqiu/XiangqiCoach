import XCTest
@testable import XiangqiCoach

final class XiangqiPositionTests: XCTestCase {
    func testStandardFENAndLegalMoveCounts() throws {
        let position = XiangqiPosition.standard
        XCTAssertEqual(position.board.compactMap { $0 }.count, 32)
        XCTAssertEqual(position.sideToMove, .red)
        XCTAssertEqual(try XCTUnwrap(XiangqiPosition(fen: position.fen())), position)
        XCTAssertEqual(position.legalMoves().count, 44)
        XCTAssertEqual(position.legalMoves().reduce(0) { $0 + position.applying($1).legalMoves().count }, 1_920)
        XCTAssertFalse(position.isInCheck(.red))
        XCTAssertFalse(position.isInCheck(.black))
    }

    func testHorseLegBlocksOnlyMatchingJumps() {
        var position = kingsWithBlocker()
        let from = Square(row: 7, column: 1)
        position[from] = Piece(side: .red, kind: .horse)
        position[Square(row: 6, column: 1)] = Piece(side: .red, kind: .pawn)
        let moves = destinations(from: from, in: position)
        XCTAssertFalse(moves.contains(Square(row: 5, column: 0)))
        XCTAssertFalse(moves.contains(Square(row: 5, column: 2)))
        XCTAssertTrue(moves.contains(Square(row: 6, column: 3)))
    }

    func testElephantCannotCrossRiverOrJumpBlockedEye() {
        var position = kingsWithBlocker()
        let from = Square(row: 5, column: 2)
        position[from] = Piece(side: .red, kind: .elephant)
        position[Square(row: 6, column: 1)] = Piece(side: .red, kind: .pawn)
        let moves = destinations(from: from, in: position)
        XCTAssertFalse(moves.contains(Square(row: 3, column: 0)))
        XCTAssertFalse(moves.contains(Square(row: 3, column: 4)))
        XCTAssertFalse(moves.contains(Square(row: 7, column: 0)))
        XCTAssertTrue(moves.contains(Square(row: 7, column: 4)))
    }

    func testCannonRequiresExactlyOneScreenToCapture() {
        var position = kingsWithBlocker()
        let from = Square(row: 7, column: 0), target = Square(row: 3, column: 0)
        position[from] = Piece(side: .red, kind: .cannon)
        position[target] = Piece(side: .black, kind: .rook)
        XCTAssertFalse(destinations(from: from, in: position).contains(target))
        position[Square(row: 5, column: 0)] = Piece(side: .red, kind: .pawn)
        XCTAssertTrue(destinations(from: from, in: position).contains(target))
        XCTAssertFalse(destinations(from: from, in: position).contains(Square(row: 4, column: 0)))
        position[Square(row: 4, column: 0)] = Piece(side: .black, kind: .pawn)
        XCTAssertFalse(destinations(from: from, in: position).contains(target))
    }

    func testPinnedPieceCannotExposeFacingGenerals() {
        var position = kingsWithBlocker()
        position[Square(row: 5, column: 4)] = nil
        let from = Square(row: 8, column: 4)
        position[from] = Piece(side: .red, kind: .rook)
        XCTAssertFalse(position.isInCheck(.red))
        let moves = destinations(from: from, in: position)
        XCTAssertFalse(moves.contains(Square(row: 8, column: 3)))
        XCTAssertTrue(moves.contains(Square(row: 7, column: 4)))
        position[from] = nil
        XCTAssertTrue(position.isInCheck(.red))
        XCTAssertTrue(position.isInCheck(.black))
    }

    func testPawnDirectionAndRiverForBothSides() {
        for side in Side.allCases {
            var position = kingsWithBlocker()
            position.sideToMove = side
            let home = Square(row: side == .red ? 6 : 3, column: 0)
            position[home] = Piece(side: side, kind: .pawn)
            XCTAssertFalse(destinations(from: home, in: position).contains(Square(row: home.row, column: 1)))
            position[home] = nil
            let crossed = Square(row: side == .red ? 4 : 5, column: 0)
            position[crossed] = Piece(side: side, kind: .pawn)
            let moves = destinations(from: crossed, in: position)
            XCTAssertTrue(moves.contains(Square(row: crossed.row, column: 1)))
            XCTAssertTrue(moves.contains(Square(row: crossed.row + (side == .red ? -1 : 1), column: 0)))
            XCTAssertFalse(moves.contains(Square(row: crossed.row + (side == .red ? 1 : -1), column: 0)))
        }
    }

    func testGeneralAndAdvisorStayInsidePalace() {
        var position = kingsWithBlocker()
        position[Square(row: 9, column: 4)] = nil
        let general = Square(row: 9, column: 3)
        position[general] = Piece(side: .red, kind: .general)
        XCTAssertFalse(destinations(from: general, in: position).contains(Square(row: 9, column: 2)))
        XCTAssertTrue(destinations(from: general, in: position).contains(Square(row: 8, column: 3)))
        let advisor = Square(row: 7, column: 3)
        position[advisor] = Piece(side: .red, kind: .advisor)
        XCTAssertEqual(destinations(from: advisor, in: position), [Square(row: 8, column: 4)])
    }

    func testApplyingMoveAndNotationPreserveBoardCoordinates() {
        let before = XiangqiPosition.standard
        let move = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        let after = before.applying(move)
        XCTAssertEqual(move.iccs(), "h2e2")
        XCTAssertEqual(MoveNotation.chinese(move, in: before), "炮二平五")
        XCTAssertEqual(after.sideToMove, .black)
        XCTAssertNil(after[move.from])
        XCTAssertEqual(after[move.to], before[move.from])
        XCTAssertEqual(Set(after.changedSquares(comparedWith: before)), Set([move.from, move.to]))
        XCTAssertNotNil(before[move.from])
        XCTAssertFalse(after.hasSameBoard(as: before))
    }

    private func kingsWithBlocker() -> XiangqiPosition {
        var position = XiangqiPosition()
        position[Square(row: 0, column: 4)] = Piece(side: .black, kind: .general)
        position[Square(row: 9, column: 4)] = Piece(side: .red, kind: .general)
        position[Square(row: 5, column: 4)] = Piece(side: .red, kind: .pawn)
        return position
    }

    private func destinations(from: Square, in position: XiangqiPosition) -> Set<Square> {
        Set(position.legalMoves().filter { $0.from == from }.map(\.to))
    }
}
