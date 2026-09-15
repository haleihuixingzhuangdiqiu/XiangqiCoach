/// 录屏、模板与识别共用一个状态源；会话版本防止旧画面或计算覆盖停止/重开后的提示。
struct CoachSessionState: Equatable {
    enum Phase: String, Equatable {
        case notRecording
        case waitingForFrame
        case preparingRecognition
        case recognitionUnavailable
        case waitingForBoard
        case confirmingBoard
        case analyzing
        case recommendation
        case finished
        case recordingStopped
    }

    private(set) var phase: Phase = .notRecording
    private(set) var isCapturing = false
    private(set) var isRecognizerReady = false
    private(set) var preparationFailed = false
    private(set) var hasReceivedFrame = false
    private(set) var generation = 0

    @discardableResult
    mutating func setCaptureActive(_ active: Bool) -> Bool {
        guard isCapturing != active else { return false }
        isCapturing = active
        hasReceivedFrame = false
        generation += 1
        phase = active ? capturePreparationPhase : .recordingStopped
        return true
    }

    mutating func setRecognizerReady(_ ready: Bool) {
        guard isRecognizerReady != ready || preparationFailed else { return }
        preparationFailed = false
        isRecognizerReady = ready
        generation += 1
        if isCapturing { phase = capturePreparationPhase }
    }

    mutating func setPreparationFailed() {
        guard !isRecognizerReady else { return }
        preparationFailed = true
        if isCapturing { phase = .recognitionUnavailable }
    }

    @discardableResult
    mutating func receiveFrame() -> Bool {
        guard isCapturing else { return false }
        if !hasReceivedFrame {
            hasReceivedFrame = true
            phase = capturePreparationPhase
        }
        return true
    }

    /// 异步结果必须携带发起时的版本，停止录屏或改变模板后不能再推进识别状态。
    @discardableResult
    mutating func advance(to phase: Phase, generation: Int) -> Bool {
        guard acceptsResult(from: generation), isRecognizerReady, hasReceivedFrame else { return false }
        switch phase {
        case .waitingForBoard, .confirmingBoard, .analyzing, .recommendation, .finished:
            self.phase = phase
            return true
        default:
            return false
        }
    }

    func acceptsResult(from generation: Int) -> Bool {
        isCapturing && self.generation == generation
    }

    private var capturePreparationPhase: Phase {
        if preparationFailed { return .recognitionUnavailable }
        if !isRecognizerReady { return .preparingRecognition }
        return hasReceivedFrame ? .waitingForBoard : .waitingForFrame
    }
}

/// 仅投影本会话与“棋研录屏”的连接，不把系统的任意录屏信号或累计帧数当作本扩展已连接。
/// lastFrameAt/now 使用同一个单调时钟；调用方在停止或开始新会话时必须清空 lastFrameAt。
/// 三秒只容忍连接短抖动，不能替代棋盘建议原有的一秒有效画面门禁。
enum CoachBroadcastConnectionState: String {
    case stopped
    case waitingForFrames
    case receiving
    case interrupted

    static func evaluate(isCaptured: Bool, lastFrameAt: Double?, now: Double) -> Self {
        guard isCaptured else { return .stopped }
        guard let lastFrameAt else { return .waitingForFrames }
        guard lastFrameAt.isFinite, now.isFinite, lastFrameAt >= 0, now >= lastFrameAt else { return .interrupted }
        return now - lastFrameAt <= 3 ? .receiving : .interrupted
    }

    var canResumeGuidance: Bool { self == .receiving }
}
