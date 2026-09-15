import Foundation

/// 一次启动意图可等待来源、前台与系统就绪；失败或用户关闭后不自动重复弹窗。
struct PiPStartState {
    enum Phase: Equatable { case idle, waiting, starting, active, stopping, stopped, failed }
    enum Action: Equatable { case start, timedOut }

    private(set) var phase: Phase = .idle
    private var requestedAt: TimeInterval = 0
    private var resumeAfterStop = false
    /// 包含等旧浮窗关闭后排队的重启；已开启或没有重启请求的用户关闭不属于待启动。
    var isPendingStart: Bool { phase == .waiting || phase == .starting || (phase == .stopping && resumeAfterStop) }
    var isStopping: Bool { phase == .stopping }
    var wantsStart: Bool { phase == .waiting || phase == .starting || phase == .active || resumeAfterStop }

    mutating func request(now: TimeInterval) {
        if isStopping {
            resumeAfterStop = true
            return
        }
        guard !wantsStart else { return }
        requestedAt = now
        phase = .waiting
    }

    /// 后台不主动启动；系统可按本次意图从 inline 自动接管，回前台时再检查可用性。
    mutating func nextAction(isReady: Bool, isForeground: Bool, now: TimeInterval) -> Action? {
        guard isForeground else { return nil }
        if isStopping {
            guard now - requestedAt >= 10 else { return nil }
            fail()
            return .timedOut
        }
        guard phase == .waiting || phase == .starting else { return nil }
        if phase == .waiting, isReady {
            requestedAt = now
            phase = .starting
            return .start
        }
        if now - requestedAt >= 10 {
            phase = .failed
            return .timedOut
        }
        return nil
    }

    mutating func willStart(now: TimeInterval) {
        if phase == .waiting {
            requestedAt = now
            phase = .starting
        }
    }

    /// 停止后的迟到 didStart 不能复活已经取消的会话。
    mutating func didStart() -> Bool {
        guard phase == .waiting || phase == .starting else { return false }
        phase = .active
        return true
    }

    mutating func fail() {
        resumeAfterStop = false
        phase = .failed
    }

    /// 系统仍在结束上一段时保留屏障；新请求必须等到旧 didStop 才能开始。
    mutating func stop(now: TimeInterval = 0, awaitsCallback: Bool = false) {
        resumeAfterStop = false
        requestedAt = now
        phase = awaitsCallback ? .stopping : .stopped
    }

    mutating func willStop(now: TimeInterval) {
        if !isStopping { stop(now: now, awaitsCallback: true) }
    }

    mutating func didStop(now: TimeInterval) {
        let shouldResume = isStopping && resumeAfterStop
        stop()
        if shouldResume { request(now: now) }
    }

    /// 来源身份变化后旧系统回调不再有效；将尚未取消的意图重新等待新来源。
    mutating func replaceSource(now: TimeInterval) {
        let shouldResume = wantsStart
        stop()
        if shouldResume { request(now: now) }
    }
}
