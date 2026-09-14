import Foundation

/// 引擎从可信起点重放实际走子，保留重复局面与长将判断所需历史；不能只传最新 FEN。
struct AnalysisHistory: Equatable, Sendable {
    let root: XiangqiPosition
    let moves: [XiangqiMove]
}

/// 只用已证明的合法走子推导轮次；识别器传入的 sideToMove 不作为事实。
/// 标准开局是红先的可信锚点，中途无法证明的局面须由用户明确同步当前轮次。
struct BoardTracker {
    enum Acceptance: Equatable {
        case newGame
        case legalMoves(Int)
        case manualSynchronization
    }

    enum Observation: Equatable {
        case confirming
        case unchanged(XiangqiPosition)
        case accepted(XiangqiPosition, Acceptance)
        case needsSynchronization
    }

    private(set) var position: XiangqiPosition?
    private(set) var analysisHistory: AnalysisHistory?
    private var candidate: XiangqiPosition?
    private var candidateCount = 0
    private var rejectedCandidate = false

    mutating func observe(_ recognized: XiangqiPosition) -> Observation {
        if candidate?.hasSameBoard(as: recognized) == true {
            candidateCount = min(candidateCount + 1, 2)
        } else {
            candidate = recognized
            candidateCount = 1
            rejectedCandidate = false
        }

        // 可信局面再次出现无需重复走子搜索，也不能受识别输入中未经验证的轮次影响。
        if let position, position.hasSameBoard(as: recognized) {
            return .unchanged(position)
        }
        guard candidateCount >= 2 else { return .confirming }
        guard !rejectedCandidate else { return .needsSynchronization }

        // 刚启动时允许追上电脑已走的一步/两步；不把任意中局按上次选择的轮次直接交给引擎。
        let previous = position ?? .standard
        if let transition = Self.provenTransition(from: previous, to: recognized) {
            position = transition.position
            let history = analysisHistory ?? AnalysisHistory(root: previous, moves: [])
            analysisHistory = AnalysisHistory(root: history.root, moves: history.moves + transition.moves)
            return .accepted(transition.position, .legalMoves(transition.moves.count))
        }
        // 合法走子也可能回到开局摆位（例如双方退马）；先证明走子，才能保留重复局面的历史。
        // 只有无法从旧局面合法返回的标准摆位，才作为新局重置。
        if recognized.hasSameBoard(as: .standard) {
            position = .standard
            analysisHistory = AnalysisHistory(root: .standard, moves: [])
            return .accepted(.standard, .newGame)
        }
        rejectedCandidate = true
        return .needsSynchronization
    }

    /// 仅同步连续稳定的最新画面；断帧/识别失败后必须重新看到稳定棋盘，不能修改旧截图的轮次。
    mutating func synchronize(sideToMove: Side) -> Observation {
        guard candidateCount >= 2, var candidate else { return .confirming }
        if candidate.hasSameBoard(as: .standard) {
            candidate = .standard
        } else {
            candidate.sideToMove = sideToMove
        }
        guard candidate.kingSquare(for: .red) != nil, candidate.kingSquare(for: .black) != nil,
              !candidate.isInCheck(candidate.sideToMove.opponent) else {
            return .needsSynchronization
        }
        rejectedCandidate = false
        position = candidate
        analysisHistory = AnalysisHistory(root: candidate, moves: [])
        return .accepted(candidate, .manualSynchronization)
    }

    /// 暂时遮挡只撤销尚未确认的画面，保留合法锚点，恢复后可证明走子或追赶。
    mutating func loseBoard() {
        candidate = nil
        candidateCount = 0
        rejectedCandidate = false
    }

    mutating func reset() {
        position = nil
        analysisHistory = nil
        loseBoard()
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
