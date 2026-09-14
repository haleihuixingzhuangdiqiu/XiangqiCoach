import Foundation

/// 搜索生命周期独立于画面可见性：短暂遮挡不重启同局计算，只有新局面或重置使旧工作失效。
struct CoachAnalysisState {
    struct Work: Equatable {
        let revision: Int
        let position: XiangqiPosition
        let startedAt: TimeInterval
    }

    struct Outcome: Equatable {
        let result: SearchResult?
        let error: String?
    }

    enum Request: Equatable {
        case start(Work)
        case inFlight
        case completed(Outcome)
    }

    private var revision = 0
    private var work: Work?
    private var outcome: Outcome?

    var isInFlight: Bool { work != nil && outcome == nil }
    var hasWork: Bool { work != nil }
    var hasFailure: Bool { outcome?.error != nil }

    mutating func request(position: XiangqiPosition, now: TimeInterval) -> Request {
        if work?.position == position {
            return outcome.map(Request.completed) ?? .inFlight
        }
        revision += 1
        let next = Work(revision: revision, position: position, startedAt: now)
        work = next
        outcome = nil
        return .start(next)
    }

    /// 完成只接收当前尚在进行的工作；已超时、停止或换局后的迟到回调不能覆盖界面。
    @discardableResult
    mutating func complete(_ completed: Work, outcome: Outcome) -> Bool {
        guard work == completed, self.outcome == nil else { return false }
        self.outcome = outcome
        return true
    }

    /// 超时保留明确失败供同局面显示，避免下一帧立即重试而永远停留在“计算中”。
    mutating func expire(now: TimeInterval, timeout: TimeInterval) -> Outcome? {
        guard let work, outcome == nil, now - work.startedAt >= timeout else { return nil }
        let failure = Outcome(result: nil, error: "计算超时，请返回教练点“同步”重试")
        outcome = failure
        return failure
    }

    mutating func reset() {
        revision += 1
        work = nil
        outcome = nil
    }
}
