import Foundation

/// 回看记录始终携带原局面与朝向，不能把旧走法套在后来确认的棋盘上。
struct CoachMoveRecall: Equatable, Sendable {
    let position: XiangqiPosition
    let move: XiangqiMove
    let boardAtBottom: Side
}

/// 只记住已正式发布的合法走法。遮挡/候选帧不改变记录；确认换局或主动重置才清除。
/// 回看与当前建议分开输出，读取回看不会延长画面有效期，也不会触发或取消搜索。
struct CoachMoveRecallState {
    private var lastPublished: CoachMoveRecall?

    @discardableResult
    mutating func remember(_ move: XiangqiMove, in position: XiangqiPosition, boardAtBottom: Side) -> Bool {
        guard position.sideToMove == boardAtBottom, position.legalMoves().contains(move) else {
            reset()
            return false
        }
        lastPublished = CoachMoveRecall(position: position, move: move, boardAtBottom: boardAtBottom)
        return true
    }

    /// 只接收已确认的局面/朝向；即使之后又回到原摆位，已清除的旧记录也不能复活。
    mutating func confirm(position: XiangqiPosition, boardAtBottom: Side) {
        guard let lastPublished else { return }
        if lastPublished.position != position || lastPublished.boardAtBottom != boardAtBottom {
            reset()
        }
    }

    /// 当前有效建议优先；无匹配棋盘、未确认朝向或停止显示棋盘时均不能回看。
    func previousSuggestion(
        for position: XiangqiPosition?, boardAtBottom: Side?, hasCurrentSuggestion: Bool
    ) -> CoachMoveRecall? {
        guard !hasCurrentSuggestion, let lastPublished,
              lastPublished.position == position, lastPublished.boardAtBottom == boardAtBottom else { return nil }
        return lastPublished
    }

    /// 录屏停止、识别重置、方向切换或手动同步的共同边界，不影响临时识别失败的恢复。
    mutating func reset() {
        lastPublished = nil
    }
}
