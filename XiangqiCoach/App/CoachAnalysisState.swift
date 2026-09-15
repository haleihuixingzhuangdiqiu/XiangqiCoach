import Foundation

/// 搜索生命周期独立于画面可见性：遮挡不重启同局计算；超时只允许一次由新鲜画面触发的重试。
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
    private var timeoutRetryCount = 0
    private var retryAvailableAt: TimeInterval?

    var isInFlight: Bool { work != nil && outcome == nil }
    var hasWork: Bool { work != nil }
    var hasFailure: Bool { outcome?.error != nil }

    /// 调用方须先确认最新棋盘有效；计时器到达冷却时间本身不能重启被遮挡棋盘的计算。
    mutating func request(position: XiangqiPosition, now: TimeInterval) -> Request {
        if work?.position == position {
            guard let retryAvailableAt, now.isFinite, now >= retryAvailableAt, timeoutRetryCount < 1 else {
                return outcome.map(Request.completed) ?? .inFlight
            }
            timeoutRetryCount += 1
            return start(position: position, now: now)
        }
        timeoutRetryCount = 0
        return start(position: position, now: now)
    }

    /// 完成只接收当前尚在进行的工作；已超时、停止或换局后的迟到回调不能覆盖界面。
    @discardableResult
    mutating func complete(_ completed: Work, outcome: Outcome) -> Bool {
        guard work == completed, self.outcome == nil else { return false }
        self.outcome = outcome
        retryAvailableAt = nil
        return true
    }

    /// 首次超时等待一秒，随后最多由新鲜画面触发一次重试；再次超时成为可执行提示的终态。
    /// 只有此入口登记重试，正常终局、引擎配置失败或错误文案中含“超时”都不能触发重试。
    mutating func expire(now: TimeInterval, timeout: TimeInterval) -> Outcome? {
        guard let work, outcome == nil, now.isFinite, timeout.isFinite, timeout > 0,
              now - work.startedAt >= timeout else { return nil }
        let canRetry = timeoutRetryCount < 1
        let failure = Outcome(result: nil, error: canRetry
            ? "计算超时，确认最新棋盘后将自动重试一次"
            : "计算再次超时，请重新开启录屏")
        outcome = failure
        retryAvailableAt = canRetry ? now + 1 : nil
        return failure
    }

    mutating func reset() {
        revision += 1
        work = nil
        outcome = nil
        timeoutRetryCount = 0
        retryAvailableAt = nil
    }

    private mutating func start(position: XiangqiPosition, now: TimeInterval) -> Request {
        revision += 1
        let next = Work(revision: revision, position: position, startedAt: now)
        work = next
        outcome = nil
        retryAvailableAt = nil
        return .start(next)
    }
}
