import Foundation

enum MoveNotation {
    private static let numerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]

    static func chinese(_ move: XiangqiMove, in position: XiangqiPosition) -> String {
        guard let piece = position[move.from] else { return move.iccs() }
        let pieceName: String
        switch (piece.side, piece.kind) {
        case (.red, .general): pieceName = "帅"
        case (.black, .general): pieceName = "将"
        case (.red, .advisor): pieceName = "仕"
        case (.black, .advisor): pieceName = "士"
        case (.red, .elephant): pieceName = "相"
        case (.black, .elephant): pieceName = "象"
        case (_, .horse): pieceName = "马"
        case (_, .rook): pieceName = "车"
        case (_, .cannon): pieceName = "炮"
        case (.red, .pawn): pieceName = "兵"
        case (.black, .pawn): pieceName = "卒"
        }
        let originFile = fileName(column: move.from.column, side: piece.side)
        if move.from.row == move.to.row {
            return "\(pieceName)\(originFile)平\(fileName(column: move.to.column, side: piece.side))"
        }
        let advances = piece.side == .red ? move.to.row < move.from.row : move.to.row > move.from.row
        let direction = advances ? "进" : "退"
        let target: String
        switch piece.kind {
        case .horse, .advisor, .elephant: target = fileName(column: move.to.column, side: piece.side)
        default: target = numerals[max(0, min(8, abs(move.to.row - move.from.row) - 1))]
        }
        return "\(pieceName)\(originFile)\(direction)\(target)"
    }

    private static func fileName(column: Int, side: Side) -> String {
        numerals[max(0, min(8, side == .red ? 8 - column : column))]
    }
}
