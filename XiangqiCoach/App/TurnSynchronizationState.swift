import Foundation

/// 点击同步只登记用户明确选择的轮次；实际应用必须等点击后两张新鲜、同盘、同朝向的录屏帧。
/// 暂时离开棋盘仅清除确认过程，停止录屏或重新准备识别才取消登记的意图。
struct TurnSynchronizationState {
    private var selectedSide: Side?
    private var requestedAt: TimeInterval = 0
    private var latestAcceptedAt: TimeInterval?
    private var candidate: XiangqiPosition?
    private var candidateBottom: Side?
    private var candidateCapturedAt: TimeInterval?
    private var candidateCount = 0

    var isPending: Bool { selectedSide != nil }

    mutating func request(sideToMove: Side, at now: TimeInterval) {
        selectedSide = sideToMove
        requestedAt = now
        latestAcceptedAt = nil
        recognitionInterrupted()
    }

    /// 返回值只代表用户请求已获得新的画面确认，仍须通过 BoardTracker 的合法性检查。
    mutating func observe(
        _ position: XiangqiPosition,
        boardAtBottom: Side,
        capturedAt: TimeInterval,
        now: TimeInterval
    ) -> Side? {
        guard let selectedSide else { return nil }
        let age = now - capturedAt
        guard capturedAt.isFinite, now.isFinite, age >= 0, age <= 1 else {
            recognitionInterrupted()
            return nil
        }
        guard capturedAt > requestedAt, capturedAt > (latestAcceptedAt ?? requestedAt) else { return nil }
        latestAcceptedAt = capturedAt
        let continuesCandidate = candidate?.hasSameBoard(as: position) == true
            && candidateBottom == boardAtBottom
            && candidateCapturedAt.map { now - $0 <= 1 } == true
        candidate = position
        candidateBottom = boardAtBottom
        candidateCapturedAt = capturedAt
        candidateCount = continuesCandidate ? min(candidateCount + 1, 2) : 1
        return candidateCount >= 2 ? selectedSide : nil
    }

    mutating func recognitionInterrupted() {
        candidate = nil
        candidateBottom = nil
        candidateCapturedAt = nil
        candidateCount = 0
    }

    mutating func reset() {
        selectedSide = nil
        latestAcceptedAt = nil
        recognitionInterrupted()
    }

    /// 已证明的开局/合法迁移优先于界面上尚未更新的选择；保留原走子历史，不能通过同步重置重复局面。
    /// 人工建立的中局锚点再次出现时仍允许用户纠正轮次。
    static func hasProvenTurn(for observation: BoardTracker.Observation, history: AnalysisHistory?) -> Bool {
        switch observation {
        case .accepted(_, .newGame), .accepted(_, .legalMoves):
            return true
        case let .unchanged(position):
            return position.hasSameBoard(as: .standard) || history?.root.hasSameBoard(as: .standard) == true
        default:
            return false
        }
    }
}
