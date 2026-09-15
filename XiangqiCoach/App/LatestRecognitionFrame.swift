import Foundation

/// 串行识别仅持有一个在算帧和一个最新待处理帧，连续来帧不会堆积旧截图。
/// 由 MainActor 使用；工作编号在重置后继续递增，旧会话回调不能释放新会话的任务。
struct LatestRecognitionFrame<Value> {
    struct Work {
        let id: UInt64
        let value: Value
        let capturedAt: TimeInterval
    }

    private var sequence: UInt64 = 0
    private var activeID: UInt64?
    private var pending: Work?
    private var latestOfferedAt = -Double.infinity

    /// 空闲时立即处理；忙时替换待处理帧，始终向最新画面收敛。
    mutating func offer(_ value: Value, capturedAt: TimeInterval) -> Work? {
        guard capturedAt.isFinite, capturedAt > latestOfferedAt else { return nil }
        latestOfferedAt = capturedAt
        sequence &+= 1
        let work = Work(id: sequence, value: value, capturedAt: capturedAt)
        guard activeID == nil else {
            pending = work
            return nil
        }
        activeID = work.id
        return work
    }

    func isCurrent(_ work: Work) -> Bool { activeID == work.id }

    /// 同一任务完成后立刻取最新帧；过期/未来时间的待处理帧不得继续占据识别队列。
    mutating func complete(_ work: Work, now: TimeInterval) -> Work? {
        guard isCurrent(work) else { return nil }
        activeID = nil
        let next = pending
        pending = nil
        guard let next, now.isFinite, now >= next.capturedAt, now - next.capturedAt <= 1 else { return nil }
        activeID = next.id
        return next
    }

    mutating func reset() {
        activeID = nil
        pending = nil
        latestOfferedAt = -Double.infinity
    }
}
