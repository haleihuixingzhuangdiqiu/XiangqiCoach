import Foundation

/// 引擎从可信起点重放实际走子，保留重复局面与长将判断所需历史；不能只传最新 FEN。
struct AnalysisHistory: Equatable, Sendable {
    let root: XiangqiPosition
    let moves: [XiangqiMove]
}

/// 只用已证明的合法走子推导轮次；识别器传入的 sideToMove 不作为事实。
/// 标准开局固定红先；未知中局只能由连续稳定且通过棋规检查的上一步标记自动建立锚点。
struct BoardTracker {
    enum Acceptance: Equatable {
        case newGame
        case legalMoves(Int)
        /// 撤回的实际步数（半回合）；上层必须使旧搜索与语音失效，再分析恢复的历史局面。
        case takeback(Int)
        /// 跨过未记录的走子恢复已确认历史段，无法准确统计撤回步数；上层同样撤销旧搜索和语音。
        case restoredHistory
        case lastMoveMarker
    }

    enum Observation: Equatable {
        case confirming
        case unchanged(XiangqiPosition)
        case accepted(XiangqiPosition, Acceptance)
        case waitingForMoveEvidence
    }

    private(set) var position: XiangqiPosition?
    private(set) var analysisHistory: AnalysisHistory?
    private var candidate: XiangqiPosition?
    private var candidateCount = 0
    private var rejectedTransition = false
    private var candidateEvidence: BoardMoveEvidence?
    private var evidenceCount = 0
    private var rejectedEvidence = false
    /// 已确认的最后一步跨遮挡保留，不能用同一个陈旧标记为后来未知的棋盘反转轮次。
    private var confirmedLastMove: BoardMoveEvidence?
    /// 未知中局可从标记建立历史根；悔棋到根时恢复这个已有证据，不能捏造根之前的走子。
    private var historyRootLastMove: BoardMoveEvidence?
    private struct HistorySegment {
        let position: XiangqiPosition
        let history: AnalysisHistory
        let rootLastMove: BoardMoveEvidence?
    }
    /// 当前段之外最多保留十五段；段间缺口始终未知，不能拼接成引擎可重放的走子历史。
    private var earlierSegments: [HistorySegment] = []
    private static let maximumHistorySegments = 16

    mutating func observe(_ recognized: XiangqiPosition, lastMove: BoardMoveEvidence? = nil) -> Observation {
        let sameCandidate = candidate?.hasSameBoard(as: recognized) == true
        if sameCandidate {
            candidateCount = min(candidateCount + 1, 2)
        } else {
            candidate = recognized
            candidateCount = 1
            rejectedTransition = false
        }
        // 棋盘稳定和标记稳定分别计数：标记缺失不妨碍合法链追赶，但不能借旧计数同步中局。
        if sameCandidate, let lastMove, candidateEvidence == lastMove {
            evidenceCount = min(evidenceCount + 1, 2)
        } else {
            candidateEvidence = lastMove
            evidenceCount = lastMove == nil ? 0 : 1
            rejectedEvidence = false
        }

        // 同一已确认棋盘的轮次属于合法历史，不受高亮标记或识别输入 sideToMove 改写。
        if let position, position.hasSameBoard(as: recognized) {
            return .unchanged(position)
        }
        guard candidateCount >= 2 else { return .confirming }

        if !rejectedTransition {
            // 合法一/两步追赶优先于标记；陈旧标记不能覆盖已证明的最后行棋方。
            let previous = position ?? .standard
            if let transition = Self.provenTransition(from: previous, to: recognized) {
                position = transition.position
                let history = analysisHistory ?? AnalysisHistory(root: previous, moves: [])
                analysisHistory = AnalysisHistory(root: history.root, moves: history.moves + transition.moves)
                if let last = transition.moves.last {
                    confirmedLastMove = BoardMoveEvidence(move: last, movedSide: transition.position.sideToMove.opponent)
                }
                return .accepted(transition.position, .legalMoves(transition.moves.count))
            }
            // 同盘可能是真实循环，所以上述向前走子先于悔棋；只有不能向前证明时才匹配历史。
            if let history = analysisHistory, let current = position,
               let restored = Self.previousPosition(matching: recognized, in: history, current: current) {
                let removedCount = history.moves.count - restored.moveCount
                let remainingMoves = Array(history.moves.prefix(restored.moveCount))
                position = restored.position
                analysisHistory = AnalysisHistory(root: history.root, moves: remainingMoves)
                confirmedLastMove = remainingMoves.last.map {
                    BoardMoveEvidence(move: $0, movedSide: restored.position.sideToMove.opponent)
                } ?? historyRootLastMove
                return .accepted(restored.position, .takeback(removedCount))
            }
            // 重锚定只中断连续走子链，不抹掉之前真正确认过的历史段；优先恢复最近的一段。
            for index in earlierSegments.indices.reversed() {
                let segment = earlierSegments[index]
                guard let restored = Self.previousPosition(matching: recognized, in: segment.history,
                                                           current: segment.position, includingEnd: true) else { continue }
                let remainingMoves = Array(segment.history.moves.prefix(restored.moveCount))
                position = restored.position
                analysisHistory = AnalysisHistory(root: segment.history.root, moves: remainingMoves)
                historyRootLastMove = segment.rootLastMove
                confirmedLastMove = remainingMoves.last.map {
                    BoardMoveEvidence(move: $0, movedSide: restored.position.sideToMove.opponent)
                } ?? historyRootLastMove
                // 被撤销的当前段和后续旧段全部丢弃，之后改走另一分支不能再自动跳回旧未来。
                earlierSegments = Array(earlierSegments.prefix(index))
                return .accepted(restored.position, .restoredHistory)
            }
            // 无法从当前历史匹配的标准摆位才建立红先新局；历史中的真实循环不被当作重新开局。
            if recognized.hasSameBoard(as: .standard) {
                position = .standard
                analysisHistory = AnalysisHistory(root: .standard, moves: [])
                confirmedLastMove = nil
                historyRootLastMove = nil
                earlierSegments.removeAll(keepingCapacity: true)
                return .accepted(.standard, .newGame)
            }
            rejectedTransition = true
        }

        guard let lastMove, evidenceCount >= 2, !rejectedEvidence,
              lastMove != confirmedLastMove else { return .waitingForMoveEvidence }
        guard let anchored = Self.positionAfterLastMove(lastMove, observed: recognized) else {
            rejectedEvidence = true
            return .waitingForMoveEvidence
        }
        if let current = position, let history = analysisHistory {
            earlierSegments.append(HistorySegment(position: current, history: history, rootLastMove: historyRootLastMove))
            let overflow = earlierSegments.count - (Self.maximumHistorySegments - 1)
            if overflow > 0 { earlierSegments.removeFirst(overflow) }
        }
        position = anchored
        // 吃子类型仅用于证明存在合法前态，不把猜测的前态写进实际走子历史。
        analysisHistory = AnalysisHistory(root: anchored, moves: [])
        confirmedLastMove = lastMove
        historyRootLastMove = lastMove
        return .accepted(anchored, .lastMoveMarker)
    }

    /// 暂时遮挡只撤销候选；旧合法锚点保留，但未知中局标记必须重新连续确认两帧。
    mutating func loseBoard() {
        candidate = nil
        candidateCount = 0
        rejectedTransition = false
        candidateEvidence = nil
        evidenceCount = 0
        rejectedEvidence = false
    }

    mutating func reset() {
        position = nil
        analysisHistory = nil
        confirmedLastMove = nil
        historyRootLastMove = nil
        earlierSegments.removeAll(keepingCapacity: true)
        loseBoard()
    }

    /// 只重放已确认的合法历史，取最近一次相同摆位；轮次来自当时局面而非识别默认值。
    /// 当前段排除其末态；旧段包含已确认的末态。不枚举任何历史根之前的可能前态。
    private static func previousPosition(matching observed: XiangqiPosition, in history: AnalysisHistory,
                                         current: XiangqiPosition, includingEnd: Bool = false) -> (position: XiangqiPosition, moveCount: Int)? {
        var replay = history.root
        var matched: (position: XiangqiPosition, moveCount: Int)?
        for (index, move) in history.moves.enumerated() {
            if replay.hasSameBoard(as: observed) { matched = (replay, index) }
            replay = replay.applying(move)
        }
        guard replay == current else { return nil }
        if includingEnd, replay.hasSameBoard(as: observed) { matched = (replay, history.moves.count) }
        return matched
    }

    /// 上一步必须能逆推为合法走子，不能只凭落点颜色宣布轮次。
    /// 炮吃子需要恢复一个可能的被吃子；只枚举有限合法类型，不要求凭当前画面猜出其真实身份。
    private static func positionAfterLastMove(_ evidence: BoardMoveEvidence, observed: XiangqiPosition) -> XiangqiPosition? {
        let move = evidence.move
        guard move.from.isOnBoard, move.to.isOnBoard, move.from != move.to,
              observed[move.from] == nil, let movedPiece = observed[move.to], movedPiece.side == evidence.movedSide,
              canOccupy(move.from, piece: movedPiece), canOccupy(move.to, piece: movedPiece) else { return nil }
        for side in Side.allCases {
            let pieces = observed.board.compactMap { $0 }.filter { $0.side == side }
            guard pieces.filter({ $0.kind == .general }).count == 1 else { return nil }
            for kind in PieceKind.allCases where kind != .general {
                guard pieces.filter({ $0.kind == kind }).count <= (kind == .pawn ? 5 : 2) else { return nil }
            }
        }
        var anchored = observed
        anchored.sideToMove = evidence.movedSide.opponent
        guard !anchored.isInCheck(evidence.movedSide) else { return nil }

        let capturedSide = evidence.movedSide.opponent
        var possibleCaptures: [Piece?] = [nil]
        for kind in PieceKind.allCases where kind != .general {
            let piece = Piece(side: capturedSide, kind: kind)
            let remaining = observed.board.compactMap { $0 }.filter { $0 == piece }.count
            if remaining < (kind == .pawn ? 5 : 2), canOccupy(move.to, piece: piece) {
                possibleCaptures.append(piece)
            }
        }
        for captured in possibleCaptures {
            var preceding = anchored
            preceding.sideToMove = evidence.movedSide
            preceding[move.from] = movedPiece
            preceding[move.to] = captured
            // 对方不能在上一步开始前已经处于被将状态；走后行棋方也不能遗留被将。
            guard !preceding.isInCheck(capturedSide), preceding.legalMoves().contains(move),
                  preceding.applying(move) == anchored else { continue }
            return anchored
        }
        return nil
    }

    /// 逆推不能把士、象、未过河兵放在棋规不可到达的位置来凑出一条“合法”走法。
    private static func canOccupy(_ square: Square, piece: Piece) -> Bool {
        guard square.isOnBoard else { return false }
        let row = piece.side == .black ? square.row : 9 - square.row
        let column = square.column
        switch piece.kind {
        case .general:
            return (0...2).contains(row) && (3...5).contains(column)
        case .advisor:
            return (row == 1 && column == 4) || ((row == 0 || row == 2) && (column == 3 || column == 5))
        case .elephant:
            return ((row == 0 || row == 4) && (column == 2 || column == 6)) || (row == 2 && [0, 4, 8].contains(column))
        case .pawn:
            return row >= 3 && (row >= 5 || column.isMultiple(of: 2))
        case .horse, .rook, .cannon:
            return true
        }
    }

    private static func provenTransition(from previous: XiangqiPosition, to observed: XiangqiPosition)
        -> (position: XiangqiPosition, moves: [XiangqiMove])? {
        let changed = previous.changedSquares(comparedWith: observed)
        guard (2...4).contains(changed.count) else { return nil }
        let firstMoves = previous.legalMoves()
        if let move = inferredMove(from: previous, to: observed), firstMoves.contains(move) {
            return (previous.applying(move), [move])
        }

        // 两步只枚举首步；第二步必须由目标的两格差异唯一推出，再验证合法性，避免无界树搜索。
        for firstMove in firstMoves {
            let intermediate = previous.applying(firstMove)
            guard let secondMove = inferredMove(from: intermediate, to: observed),
                  intermediate.legalMoves().contains(secondMove) else { continue }
            return (intermediate.applying(secondMove), [firstMove, secondMove])
        }
        return nil
    }

    private static func inferredMove(from previous: XiangqiPosition, to observed: XiangqiPosition) -> XiangqiMove? {
        let changed = previous.changedSquares(comparedWith: observed)
        guard changed.count == 2 else { return nil }
        for source in changed {
            guard let piece = previous[source], piece.side == previous.sideToMove, observed[source] == nil,
                  let destination = changed.first(where: { $0 != source }), observed[destination] == piece else { continue }
            let move = XiangqiMove(from: source, to: destination)
            guard previous.applying(move).hasSameBoard(as: observed) else { continue }
            return move
        }
        return nil
    }
}
