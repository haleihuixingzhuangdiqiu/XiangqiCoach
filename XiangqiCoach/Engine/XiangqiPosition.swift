import Foundation

enum Side: String, Codable, CaseIterable, Sendable {
    case red
    case black

    var opponent: Side { self == .red ? .black : .red }
    var displayName: String { self == .red ? "红方" : "黑方" }
}

enum PieceKind: String, Codable, CaseIterable, Sendable {
    case general
    case advisor
    case elephant
    case horse
    case rook
    case cannon
    case pawn
}

struct Piece: Codable, Equatable, Hashable, Sendable {
    let side: Side
    let kind: PieceKind
}

struct Square: Codable, Equatable, Hashable, Sendable {
    let row: Int
    let column: Int

    var isOnBoard: Bool {
        (0..<10).contains(row) && (0..<9).contains(column)
    }
}

struct XiangqiMove: Codable, Equatable, Hashable, Sendable {
    let from: Square
    let to: Square

    func iccs() -> String {
        guard from.isOnBoard, to.isOnBoard else { return "0000" }
        let files = Array("abcdefghi")
        return "\(files[from.column])\(9 - from.row)\(files[to.column])\(9 - to.row)"
    }
}

struct XiangqiPosition: Equatable, Sendable {
    private(set) var board: [Piece?]
    var sideToMove: Side

    init(board: [Piece?] = Array(repeating: nil, count: 90), sideToMove: Side = .red) {
        precondition(board.count == 90)
        self.board = board
        self.sideToMove = sideToMove
    }

    static let standard = XiangqiPosition(fen: "rheakaehr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RHEAKAEHR r")!

    init?(fen: String) {
        let parts = fen.split(separator: " ")
        guard let placement = parts.first else { return nil }
        let rows = placement.split(separator: "/")
        guard rows.count == 10 else { return nil }

        var parsed = Array<Piece?>(repeating: nil, count: 90)
        for (row, encodedRow) in rows.enumerated() {
            var column = 0
            for scalar in encodedRow {
                if let gap = scalar.wholeNumberValue {
                    column += gap
                    continue
                }
                guard column < 9, let piece = Self.piece(from: scalar) else { return nil }
                parsed[row * 9 + column] = piece
                column += 1
            }
            guard column == 9 else { return nil }
        }

        board = parsed
        sideToMove = parts.count > 1 && parts[1].lowercased() == "b" ? .black : .red
    }

    subscript(_ square: Square) -> Piece? {
        get {
            guard square.isOnBoard else { return nil }
            return board[square.row * 9 + square.column]
        }
        set {
            guard square.isOnBoard else { return }
            board[square.row * 9 + square.column] = newValue
        }
    }

    func fen() -> String {
        let placement = (0..<10).map { row -> String in
            var result = ""
            var emptyCount = 0
            for column in 0..<9 {
                if let piece = self[Square(row: row, column: column)] {
                    if emptyCount > 0 {
                        result.append(String(emptyCount))
                        emptyCount = 0
                    }
                    result.append(Self.fenCharacter(for: piece))
                } else { emptyCount += 1 }
            }
            if emptyCount > 0 { result.append(String(emptyCount)) }
            return result
        }.joined(separator: "/")
        return "\(placement) \(sideToMove == .red ? "r" : "b")"
    }

    /// 调用方先验证合法性；纯值变换保持原局面不变。
    func applying(_ move: XiangqiMove) -> XiangqiPosition {
        var next = applyingWithoutTurn(move)
        next.sideToMove = sideToMove.opponent
        return next
    }

    func legalMoves(for side: Side? = nil) -> [XiangqiMove] {
        let movingSide = side ?? sideToMove
        return pseudoMoves(for: movingSide).filter { move in
            let next = applyingWithoutTurn(move)
            return next.kingSquare(for: movingSide) != nil && !next.isInCheck(movingSide)
        }
    }

    func isInCheck(_ side: Side) -> Bool {
        guard let king = kingSquare(for: side) else { return true }
        return pseudoMoves(for: side.opponent).contains { $0.to == king }
    }

    func kingSquare(for side: Side) -> Square? {
        for row in 0..<10 {
            for column in 0..<9 {
                let square = Square(row: row, column: column)
                if self[square] == Piece(side: side, kind: .general) { return square }
            }
        }
        return nil
    }

    func changedSquares(comparedWith other: XiangqiPosition) -> [Square] {
        (0..<90).compactMap { index in
            board[index] == other.board[index] ? nil : Square(row: index / 9, column: index % 9)
        }
    }

    func hasSameBoard(as other: XiangqiPosition) -> Bool {
        board == other.board
    }

    private func applyingWithoutTurn(_ move: XiangqiMove) -> XiangqiPosition {
        var next = self
        next[move.to] = next[move.from]
        next[move.from] = nil
        return next
    }

    private func pseudoMoves(for side: Side) -> [XiangqiMove] {
        var result: [XiangqiMove] = []
        for row in 0..<10 {
            for column in 0..<9 {
                let from = Square(row: row, column: column)
                guard let piece = self[from], piece.side == side else { continue }
                result.append(contentsOf: pseudoMoves(for: piece, from: from))
            }
        }
        return result
    }

    private func pseudoMoves(for piece: Piece, from: Square) -> [XiangqiMove] {
        switch piece.kind {
        case .general:
            return generalMoves(for: piece, from: from)
        case .advisor:
            return advisorMoves(for: piece, from: from)
        case .elephant:
            return elephantMoves(for: piece, from: from)
        case .horse:
            return horseMoves(for: piece, from: from)
        case .rook:
            return slidingMoves(for: piece, from: from, cannon: false)
        case .cannon:
            return slidingMoves(for: piece, from: from, cannon: true)
        case .pawn:
            return pawnMoves(for: piece, from: from)
        }
    }

    private func generalMoves(for piece: Piece, from: Square) -> [XiangqiMove] {
        let palaceRows = piece.side == .red ? 7...9 : 0...2
        var moves = orthogonalTargets(from: from).compactMap { to -> XiangqiMove? in
            guard palaceRows.contains(to.row), (3...5).contains(to.column), canLand(piece, on: to) else { return nil }
            return XiangqiMove(from: from, to: to)
        }

        let direction = piece.side == .red ? -1 : 1
        var row = from.row + direction
        while (0..<10).contains(row) {
            let target = Square(row: row, column: from.column)
            if let hit = self[target] {
                if hit.side != piece.side, hit.kind == .general {
                    moves.append(XiangqiMove(from: from, to: target))
                }
                break
            }
            row += direction
        }
        return moves
    }

    private func advisorMoves(for piece: Piece, from: Square) -> [XiangqiMove] {
        let palaceRows = piece.side == .red ? 7...9 : 0...2
        return [(-1, -1), (-1, 1), (1, -1), (1, 1)].compactMap { delta in
            let to = Square(row: from.row + delta.0, column: from.column + delta.1)
            guard to.isOnBoard, palaceRows.contains(to.row), (3...5).contains(to.column), canLand(piece, on: to) else { return nil }
            return XiangqiMove(from: from, to: to)
        }
    }

    private func elephantMoves(for piece: Piece, from: Square) -> [XiangqiMove] {
        [(-2, -2), (-2, 2), (2, -2), (2, 2)].compactMap { delta in
            let to = Square(row: from.row + delta.0, column: from.column + delta.1)
            let eye = Square(row: from.row + delta.0 / 2, column: from.column + delta.1 / 2)
            let staysHome = piece.side == .red ? to.row >= 5 : to.row <= 4
            guard to.isOnBoard, staysHome, self[eye] == nil, canLand(piece, on: to) else { return nil }
            return XiangqiMove(from: from, to: to)
        }
    }

    private func horseMoves(for piece: Piece, from: Square) -> [XiangqiMove] {
        let patterns = [
            (-2, -1, -1, 0), (-2, 1, -1, 0),
            (2, -1, 1, 0), (2, 1, 1, 0),
            (-1, -2, 0, -1), (1, -2, 0, -1),
            (-1, 2, 0, 1), (1, 2, 0, 1),
        ]
        return patterns.compactMap { dr, dc, lr, lc in
            let to = Square(row: from.row + dr, column: from.column + dc)
            let leg = Square(row: from.row + lr, column: from.column + lc)
            guard canLand(piece, on: to), self[leg] == nil else { return nil }
            return XiangqiMove(from: from, to: to)
        }
    }

    private func slidingMoves(for piece: Piece, from: Square, cannon: Bool) -> [XiangqiMove] {
        var result: [XiangqiMove] = []
        for (dr, dc) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            var row = from.row + dr, column = from.column + dc
            var screened = false
            while Square(row: row, column: column).isOnBoard {
                let to = Square(row: row, column: column)
                let occupant = self[to]
                if !screened {
                    if occupant == nil { result.append(XiangqiMove(from: from, to: to)) }
                    else if !cannon {
                        if occupant?.side != piece.side { result.append(XiangqiMove(from: from, to: to)) }
                        break
                    } else { screened = true }
                } else if occupant != nil {
                    if occupant?.side != piece.side { result.append(XiangqiMove(from: from, to: to)) }
                    break
                }
                row += dr
                column += dc
            }
        }
        return result
    }

    private func pawnMoves(for piece: Piece, from: Square) -> [XiangqiMove] {
        var targets = [Square(row: from.row + (piece.side == .red ? -1 : 1), column: from.column)]
        if piece.side == .red ? from.row <= 4 : from.row >= 5 {
            targets += [Square(row: from.row, column: from.column - 1), Square(row: from.row, column: from.column + 1)]
        }
        return targets.filter { canLand(piece, on: $0) }.map { XiangqiMove(from: from, to: $0) }
    }

    private func canLand(_ piece: Piece, on square: Square) -> Bool {
        square.isOnBoard && self[square]?.side != piece.side
    }

    private func orthogonalTargets(from: Square) -> [Square] {
        [(1, 0), (-1, 0), (0, 1), (0, -1)].map { Square(row: from.row + $0.0, column: from.column + $0.1) }
    }

    private static func piece(from character: Character) -> Piece? {
        let kind: PieceKind
        switch character.lowercased() {
        case "k": kind = .general
        case "a": kind = .advisor
        case "e", "b": kind = .elephant
        case "h", "n": kind = .horse
        case "r": kind = .rook
        case "c": kind = .cannon
        case "p": kind = .pawn
        default: return nil
        }
        return Piece(side: character.isUppercase ? .red : .black, kind: kind)
    }

    private static func fenCharacter(for piece: Piece) -> Character {
        let value: String
        switch piece.kind {
        case .general: value = "k"
        case .advisor: value = "a"
        case .elephant: value = "e"
        case .horse: value = "h"
        case .rook: value = "r"
        case .cannon: value = "c"
        case .pawn: value = "p"
        }
        return Character(piece.side == .red ? value.uppercased() : value)
    }
}
