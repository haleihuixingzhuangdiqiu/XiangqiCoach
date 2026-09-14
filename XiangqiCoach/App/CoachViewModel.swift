import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class CoachViewModel: ObservableObject {
    @Published var manualSideToMove: Side = .red
    @Published var voiceEnabled = true
    @Published var autoStartPictureInPicture = true

    @Published private(set) var isRecognizerReady = false
    @Published private(set) var recognitionPreparationStatus = "正在准备棋盘识别…"
    @Published private(set) var captureStatus = "等待系统录屏"
    @Published private(set) var recognitionStatus = "尚未收到画面"
    @Published private(set) var latencyStatus = "等待录屏画面"
    @Published private(set) var livePreview: UIImage?
    @Published private(set) var recommendation = "等待棋盘"
    @Published private(set) var recommendationDetail = "正在准备棋盘识别"
    @Published private(set) var receivedFrameCount = 0
    @Published private(set) var isScreenCaptured = false

    let pipController: PiPCoachController

    private let receiver = FrameReceiver()
    private let recognitionQueue = DispatchQueue(label: "com.lgj.xiangqicoach.recognition", qos: .userInitiated)
    private let engineQueue = DispatchQueue(label: "com.lgj.xiangqicoach.engine", qos: .userInitiated)
    private let engine = XiangqiEngine()
    private let speech = AVSpeechSynthesizer()
    private let diagnostics = CoachDiagnostics()

    /// 单独保留监听器状态，防止系统“录屏已开启”覆盖真正的传输错误。
    private var receiverStatus = "正在启动录屏接收器"
    private var recognizer: BoardRecognizer?
    private var analyzingFrame = false
    private var boardTracker = BoardTracker()
    private var turnSynchronization = TurnSynchronizationState()
    private var currentPosition: XiangqiPosition? { boardTracker.position }
    private var suggestedMove: XiangqiMove?
    private var analysisState = CoachAnalysisState()
    private var analysisTicket: AnalysisTicket?
    private var engineFailureMessage: String?
    private var didAnnounceRecommendation = false

    private var recognizerGeneration = 0
    private var session = CoachSessionState()
    private var captureObserver: NSObjectProtocol?
    private var freshnessTimer: Timer?
    /// 全链路使用开机后的单调时间；超过一秒的画面不能继续提供落子指引。
    private let maximumFrameAge: TimeInterval = 1
    private var lastFrameCapturedAt: TimeInterval?
    private var lastConfirmedFrameAt: TimeInterval?
    private var lastRecognitionMilliseconds: Double?
    private var lastFrameLatencyMilliseconds: Double?
    private var lastEngineMilliseconds: Int?
    private var lastEngineResultDepth: Int?
    private var recognitionWaitDetail = "请打开指定的对局棋盘，并露出全部棋子"
    private var requiresTurnSynchronization = false
    private var recognizedBoardAtBottom: Side?
    private var orientationCandidate: Side?
    private var orientationCandidateCount = 0

    init(pipController: PiPCoachController) {
        self.pipController = pipController
        receiver.onFrame = { [weak self] image, capturedAt in
            Task { @MainActor in self?.ingest(image, capturedAt: capturedAt) }
        }
        receiver.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.receiverStatus = status
                self.captureStatus = status
                self.writeDiagnostics()
            }
        }
        receiver.start()

        updateCaptureState(UIScreen.main.isCaptured)
        captureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: UIScreen.main,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateCaptureState(UIScreen.main.isCaptured)
                if self.isScreenCaptured, self.autoStartPictureInPicture {
                    // 系统录屏必须由用户确认；确认完成后自动悬浮，减少切换 App 前的额外操作。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        guard let self, self.isScreenCaptured, !self.pipController.isPictureInPictureActive else { return }
                        self.pipController.start()
                    }
                }
            }
        }

        prepareRecognizer()
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFrameFreshness() }
        }
        if let freshnessTimer { RunLoop.main.add(freshnessTimer, forMode: .common) }
    }

    deinit {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        freshnessTimer?.invalidate()
    }

    func resynchronizeTurn() {
        guard session.isCapturing else {
            recognitionStatus = "请先开启录屏，再同步当前轮次"
            return
        }
        // 教练页面会遮住外部棋盘，因此先登记意图；不依赖返回页面之前的截图来改轮次。
        turnSynchronization.request(sideToMove: manualSideToMove, at: ProcessInfo.processInfo.systemUptime)
        boardTracker.loseBoard()
        invalidateAnalysis()
        recognitionStatus = "已登记\(manualSideToMove.displayName)轮次，请切回棋盘"
        showRecognitionWait(.waitingForBoard, detail: "切回棋盘并保持稳定，确认最新画面后自动同步")
    }

    func startPictureInPicture() {
        updateCaptureState(UIScreen.main.isCaptured)
        updateOverlay()
        pipController.start()
    }

    func stopPictureInPicture() {
        pipController.stop()
    }

    private func prepareRecognizer() {
        // 一次准备两种颜色的模板；执棋方只能从后续真实画面确认，不能由设置或默认值指定。
        recognizerGeneration += 1
        let generation = recognizerGeneration
        recognizer = nil
        isRecognizerReady = false
        recognitionPreparationStatus = "正在准备棋盘识别…"
        session.setRecognizerReady(false)
        resetRecognition()
        updateOverlay()

        recognitionQueue.async { [weak self] in
            let result = Result { try BoardRecognizer.preset() }
            DispatchQueue.main.async {
                guard let self, generation == self.recognizerGeneration else { return }
                switch result {
                case let .success(recognizer):
                    self.recognizer = recognizer
                    self.isRecognizerReady = true
                    self.recognitionPreparationStatus = "棋盘识别已就绪"
                    self.session.setRecognizerReady(true)
                case let .failure(error):
                    self.recognitionPreparationStatus = "识别准备失败：\(error.localizedDescription)"
                    self.session.setPreparationFailed()
                }
                self.updateOverlay()
            }
        }
    }

    private func ingest(_ image: CGImage, capturedAt: TimeInterval) {
        // 首帧可能先于系统通知抵达；使用当前系统值补齐开始事件，停止后的排队帧则丢弃。
        updateCaptureState(UIScreen.main.isCaptured)
        guard session.receiveFrame() else { return }
        receivedFrameCount += 1
        updateLatency(capturedAt: capturedAt)
        guard isFresh(capturedAt), capturedAt > (lastFrameCapturedAt ?? 0) else {
            checkFrameFreshness()
            return
        }
        lastFrameCapturedAt = capturedAt
        livePreview = UIImage(cgImage: image)
        captureStatus = "录屏中 · 已收到画面"
        updateOverlay()
        guard let recognizer else {
            recognitionStatus = recognitionPreparationStatus
            return
        }
        guard !analyzingFrame else { return }
        analyzingFrame = true
        let sideToMove = currentPosition?.sideToMove ?? manualSideToMove
        let sessionGeneration = session.generation

        recognitionQueue.async { [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = Result { try recognizer.recognize(image, sideToMove: sideToMove) }
            let recognitionMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.session.acceptsResult(from: sessionGeneration) else { return }
                self.analyzingFrame = false
                self.lastRecognitionMilliseconds = recognitionMilliseconds
                self.updateLatency(capturedAt: capturedAt)
                guard self.isFresh(capturedAt) else {
                    self.boardTracker.loseBoard()
                    self.turnSynchronization.recognitionInterrupted()
                    self.orientationCandidate = nil
                    self.orientationCandidateCount = 0
                    self.lastConfirmedFrameAt = nil
                    self.recognitionStatus = "已丢弃延迟画面，等待最新棋盘"
                    self.showRecognitionWait(.waitingForBoard, detail: "画面延迟，请等待最新棋盘")
                    return
                }
                switch result {
                case let .success(recognition):
                    self.handleRecognition(recognition, capturedAt: capturedAt)
                case let .failure(error):
                    self.recognitionStatus = "识别暂停：\(error.localizedDescription)"
                    self.boardTracker.loseBoard()
                    self.turnSynchronization.recognitionInterrupted()
                    self.orientationCandidate = nil
                    self.orientationCandidateCount = 0
                    self.lastConfirmedFrameAt = nil
                    self.showRecognitionWait(.waitingForBoard)
                }
            }
        }
    }

    private func handleRecognition(_ recognition: RecognitionResult, capturedAt: TimeInterval) {
        if orientationCandidate == recognition.boardAtBottom {
            orientationCandidateCount = min(orientationCandidateCount + 1, 2)
        } else {
            orientationCandidate = recognition.boardAtBottom
            orientationCandidateCount = 1
        }
        var observation = boardTracker.observe(recognition.position)
        if turnSynchronization.isPending {
            guard let selectedSide = turnSynchronization.observe(
                recognition.position, boardAtBottom: recognition.boardAtBottom,
                capturedAt: capturedAt, now: ProcessInfo.processInfo.systemUptime
            ), confirmObservedSide(recognition.boardAtBottom) else {
                recognitionStatus = "正在确认同步所需的最新棋盘…"
                showRecognitionWait(.confirmingBoard, detail: "请保持完整棋盘稳定，确认两张新画面后同步")
                return
            }
            if !TurnSynchronizationState.hasProvenTurn(for: observation, history: boardTracker.analysisHistory) {
                observation = boardTracker.synchronize(sideToMove: selectedSide)
                guard case .accepted = observation else {
                    turnSynchronization.reset()
                    recognitionStatus = "所选轮次与当前局面不符，请确认后重新同步"
                    showRecognitionWait(.confirmingBoard, detail: "返回教练确认当前轮次，再点“同步”", requiresSynchronization: true)
                    return
                }
            }
            if case let .unchanged(position) = observation { manualSideToMove = position.sideToMove }
            turnSynchronization.reset()
        }
        switch observation {
        case .confirming:
            recognitionStatus = "正在确认局面…"
            showRecognitionWait(.confirmingBoard)
        case .needsSynchronization:
            _ = confirmObservedSide(recognition.boardAtBottom)
            recognitionStatus = "局面未同步，不能确定轮次"
            showRecognitionWait(.confirmingBoard, detail: "返回教练确认当前轮次，再点“同步”", requiresSynchronization: true)
        case let .unchanged(position):
            guard confirmObservedSide(recognition.boardAtBottom) else {
                showRecognitionWait(.confirmingBoard, detail: "正在确认棋盘朝向，请保持画面稳定")
                return
            }
            lastConfirmedFrameAt = capturedAt
            recognitionStatus = "局面稳定 · \(recognition.qualityText)"
            analyzeIfNeeded(position)
        case let .accepted(position, reason):
            manualSideToMove = position.sideToMove
            guard confirmObservedSide(recognition.boardAtBottom) else {
                showRecognitionWait(.confirmingBoard, detail: "正在确认棋盘朝向，请保持画面稳定")
                return
            }
            lastConfirmedFrameAt = capturedAt
            switch reason {
            case .newGame:
                recognitionStatus = "已识别新局 · 红方先行"
            case let .legalMoves(count):
                recognitionStatus = "已同步\(count)步 · \(position.sideToMove.displayName)走"
            case .manualSynchronization:
                recognitionStatus = "已同步 · \(position.sideToMove.displayName)走"
            }
            analyzeIfNeeded(position)
        }
    }

    /// 实测朝向由将帅位置和颜色确认；内部同步不重新加载模板，也不丢弃刚证明的局面。
    private func confirmObservedSide(_ side: Side) -> Bool {
        if recognizedBoardAtBottom == side { return true }
        guard orientationCandidateCount >= 2 else { return false }
        // 新确认的朝向替代旧朝向时撤销旧侧搜索，但不重载模板、不丢弃已证明的棋局。
        invalidateAnalysis()
        recognizedBoardAtBottom = side
        return true
    }

    private func analyzeIfNeeded(_ position: XiangqiPosition) {
        guard session.isCapturing, session.isRecognizerReady, session.hasReceivedFrame else { return }
        guard let lastConfirmedFrameAt, isFresh(lastConfirmedFrameAt) else { return }
        let sessionGeneration = session.generation
        requiresTurnSynchronization = false

        guard let boardAtBottom = recognizedBoardAtBottom else { return }
        guard position.sideToMove == boardAtBottom else {
            if analysisState.hasWork { invalidateAnalysis() }
            suggestedMove = nil
            session.advance(to: .waitingForOpponent, generation: sessionGeneration)
            updateOverlay()
            return
        }

        let request = analysisState.request(position: position, now: ProcessInfo.processInfo.systemUptime)
        if case let .completed(outcome) = request {
            // 同局建议已显示时保持不动；从遮挡恢复则直接恢复已完成结果，不重复计算/播报每一帧。
            if session.phase != .recommendation && session.phase != .finished {
                publish(outcome.result, engineError: outcome.error, for: position)
            }
            return
        }

        if case .start = request {
            engine.cancel()
            analysisTicket?.cancel()
            suggestedMove = nil
            engineFailureMessage = nil
            didAnnounceRecommendation = false
            lastEngineMilliseconds = nil
            lastEngineResultDepth = nil
        }
        session.advance(to: .analyzing, generation: sessionGeneration)
        updateOverlay()
        guard case let .start(work) = request else { return }


        let engine = engine
        let history = boardTracker.analysisHistory
        let ticket = AnalysisTicket()
        analysisTicket = ticket
        engineQueue.async { [weak self] in
            // 已被新局面替代的排队任务直接跳过；不让陈旧局面逐个占用引擎预算。
            guard !ticket.isCancelled, let self else { return }
            let result = engine.search(position: position, history: history)
            let engineError = engine.lastError
            DispatchQueue.main.async {
                guard
                    self.session.acceptsResult(from: sessionGeneration),
                    self.currentPosition == position,
                    self.analysisState.complete(work, outcome: .init(result: result, error: engineError))
                else {
                    return
                }
                self.analysisTicket = nil
                self.lastEngineMilliseconds = result?.elapsedMilliseconds
                self.lastEngineResultDepth = result?.depth
                guard let lastConfirmedFrameAt = self.lastConfirmedFrameAt, self.isFresh(lastConfirmedFrameAt) else {
                    // 结果已缓存，等同局面重获确认再发布；不能用旧结果强制改变遮挡/轮次同步提示。
                    if self.session.phase == .analyzing {
                        self.showRecognitionWait(.waitingForBoard, detail: "计算已完成，等待确认当前棋盘")
                    } else {
                        self.updateOverlay()
                    }
                    return
                }
                self.publish(result, engineError: engineError, for: position)
            }
        }
    }

    private func publish(_ result: SearchResult?, engineError: String?, for position: XiangqiPosition) {
        lastEngineMilliseconds = result?.elapsedMilliseconds
        lastEngineResultDepth = result?.depth
        if let lastFrameCapturedAt { updateLatency(capturedAt: lastFrameCapturedAt) }
        guard let result else {
            suggestedMove = nil
            engineFailureMessage = engineError
            if let engineError {
                recommendation = "计算暂不可用"
                recommendationDetail = engineError
            } else {
                recommendation = position.isInCheck(position.sideToMove) ? "已被将死" : "当前无合法着法"
                recommendationDetail = "请开始新局"
            }
            session.advance(to: .finished, generation: session.generation)
            updateOverlay()
            return
        }

        let notation = MoveNotation.chinese(result.move, in: position)
        suggestedMove = result.move
        let scoreText = String(format: "%+.2f", Double(result.score) / 100)
        recommendation = notation
        recommendationDetail = "\(result.move.iccs()) · 深度 \(result.depth) · 评分 \(scoreText)"
        session.advance(to: .recommendation, generation: session.generation)
        updateOverlay()

        if voiceEnabled && !didAnnounceRecommendation {
            didAnnounceRecommendation = true
            speech.stopSpeaking(at: .word)
            let utterance = AVSpeechUtterance(string: "建议，\(notation)")
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.46
            speech.speak(utterance)
        }
    }

    private func updateCaptureState(_ captured: Bool) {
        isScreenCaptured = captured
        guard session.setCaptureActive(captured) else { return }
        resetRecognition()
        captureStatus = captured ? "系统录屏已开启" : "录屏已停止"
        recognitionStatus = captured ? "等待录屏画面" : "识别已暂停"
        updateOverlay()
    }

    private func resetRecognition() {
        invalidateAnalysis()
        turnSynchronization.reset()
        analyzingFrame = false
        boardTracker.reset()
        recognizedBoardAtBottom = nil
        orientationCandidate = nil
        orientationCandidateCount = 0
        lastFrameCapturedAt = nil
        lastConfirmedFrameAt = nil
        lastRecognitionMilliseconds = nil
        lastFrameLatencyMilliseconds = nil
        lastEngineMilliseconds = nil
        lastEngineResultDepth = nil
        engineFailureMessage = nil
        suggestedMove = nil
    }

    /// 只有明确换局、改方向、停止或手动重试才使计算失效，短暂识别失败不走此入口。
    private func invalidateAnalysis() {
        engine.cancel()
        analysisTicket?.cancel()
        analysisTicket = nil
        analysisState.reset()
        engineFailureMessage = nil
        didAnnounceRecommendation = false
        suggestedMove = nil
        speech.stopSpeaking(at: .immediate)
    }

    private func showRecognitionWait(
        _ phase: CoachSessionState.Phase,
        detail: String = "请打开指定的对局棋盘，并露出全部棋子",
        requiresSynchronization: Bool = false
    ) {
        // 画面暂不可信只撤销落子指引，仍显示上次确认棋盘并让同局计算完成。
        // 必须清确认时间，防止遮挡期间搜索刚完成就把旧箭头重新显示出来。
        lastConfirmedFrameAt = nil
        suggestedMove = nil
        recognitionWaitDetail = detail
        requiresTurnSynchronization = requiresSynchronization
        speech.stopSpeaking(at: .immediate)
        session.advance(to: phase, generation: session.generation)
        updateOverlay()
    }

    private func isFresh(_ capturedAt: TimeInterval) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - capturedAt
        return age >= 0 && age <= maximumFrameAge
    }

    private func checkFrameFreshness() {
        checkAnalysisTimeout()
        // 即使录屏已停，下一次低频 tick 仍可把最终状态落盘，避免限频丢掉停止事件。
        writeDiagnostics()
        guard session.isCapturing, let lastFrameCapturedAt else { return }
        guard !isFresh(lastFrameCapturedAt) else { return }
        boardTracker.loseBoard()
        turnSynchronization.recognitionInterrupted()
        orientationCandidate = nil
        orientationCandidateCount = 0
        lastConfirmedFrameAt = nil
        captureStatus = "画面已中断 · 等待最新录屏"
        recognitionStatus = "旧画面已暂停指引"
        updateLatency(capturedAt: lastFrameCapturedAt)
        showRecognitionWait(.waitingForBoard, detail: "超过一秒未收到新画面，指引已暂停")
    }

    private func checkAnalysisTimeout() {
        guard let outcome = analysisState.expire(now: ProcessInfo.processInfo.systemUptime, timeout: 3) else { return }
        engine.cancel()
        analysisTicket?.cancel()
        analysisTicket = nil
        guard let position = currentPosition, let lastConfirmedFrameAt, isFresh(lastConfirmedFrameAt) else {
            if session.phase == .analyzing {
                showRecognitionWait(.waitingForBoard, detail: "等待确认当前棋盘后重试计算")
            } else {
                updateOverlay()
            }
            return
        }
        publish(outcome.result, engineError: outcome.error, for: position)
    }

    private func updateLatency(capturedAt: TimeInterval) {
        let frameMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - capturedAt) * 1_000
        lastFrameLatencyMilliseconds = frameMilliseconds
        let recognition = lastRecognitionMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        let engine = lastEngineMilliseconds.map { "\($0) ms" } ?? "—"
        latencyStatus = String(format: "画面 %.0f ms · 识别 %@ · 计算 %@", frameMilliseconds, recognition, engine)
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        let confirmedFEN: String?
        switch session.phase {
        case .analyzing, .waitingForOpponent, .recommendation, .finished:
            confirmedFEN = currentPosition?.fen()
        default:
            confirmedFEN = nil
        }
        diagnostics.submit(CoachDiagnosticsSnapshot(
            phase: session.phase.rawValue,
            displayedFEN: pipController.state.position?.fen(),
            boardIsCurrent: pipController.state.boardIsCurrent,
            isAnalyzing: analysisState.isInFlight,
            isScreenCaptured: isScreenCaptured,
            receivedFrameCount: receivedFrameCount,
            captureStatus: captureStatus,
            receiverStatus: receiverStatus,
            applicationState: String(describing: UIApplication.shared.applicationState),
            isPictureInPictureActive: pipController.isPictureInPictureActive,
            isPictureInPicturePossible: pipController.isPictureInPicturePossible,
            pictureInPictureError: pipController.errorMessage,
            recognitionStatus: recognitionStatus,
            frameLatencyMilliseconds: lastFrameLatencyMilliseconds,
            recognitionMilliseconds: lastRecognitionMilliseconds,
            engineMilliseconds: lastEngineMilliseconds,
            confirmedFEN: confirmedFEN,
            actualSide: recognizedBoardAtBottom,
            engineResultDepth: lastEngineResultDepth,
            engineMove: suggestedMove?.iccs(),
            engineError: engineFailureMessage
        ))
    }

    private func updateOverlay() {
        var state: CoachOverlayState
        switch session.phase {
        case .notRecording:
            state = CoachOverlayState()
        case .waitingForFrame:
            state = CoachOverlayState(title: "录屏已开启", move: "等待录屏画面", detail: "请确认选择了“棋研录屏”", accent: .systemYellow)
        case .preparingRecognition:
            let title = session.hasReceivedFrame ? "已收到录屏画面" : "录屏已开启"
            state = CoachOverlayState(title: title, move: "正在准备识别…", detail: "请稍候", accent: .systemYellow)
        case .recognitionUnavailable:
            state = CoachOverlayState(title: "录屏已开启", move: "识别暂不可用", detail: recognitionPreparationStatus, accent: .systemOrange)
        case .waitingForBoard:
            state = CoachOverlayState(title: "已收到录屏画面", move: "等待棋盘", detail: recognitionWaitDetail, accent: .systemYellow)
        case .confirmingBoard:
            state = CoachOverlayState(title: "已收到录屏画面", move: requiresTurnSynchronization ? "请同步当前轮次" : "正在确认局面…",
                                      detail: recognitionWaitDetail, accent: .systemYellow)
        case .analyzing:
            state = CoachOverlayState(title: "\(manualSideToMove.displayName) · 正在分析", move: "计算中…", detail: "请稍候", accent: .systemYellow)
        case .waitingForOpponent:
            state = CoachOverlayState(title: "对局棋盘 · 等待对方", move: "等待对方走棋", detail: "局面识别正常", accent: .systemOrange)
        case .recommendation:
            state = CoachOverlayState(title: "\(manualSideToMove.displayName)建议", move: recommendation, detail: recommendationDetail, accent: .systemGreen)
        case .finished:
            state = CoachOverlayState(title: engineFailureMessage == nil ? "分析完成" : "计算失败", move: recommendation,
                                      detail: recommendationDetail, accent: .systemRed)
        case .recordingStopped:
            state = CoachOverlayState(title: "录屏已停止", move: "指导已暂停", detail: "返回教练重新开启“棋研录屏”", accent: .systemOrange)
        }
        // 棋盘是独立于搜索状态的持久内容；等待识别/思考不再把整个浮窗切成白底。
        state.position = session.isCapturing && recognizedBoardAtBottom != nil ? currentPosition : nil
        state.boardIsCurrent = lastConfirmedFrameAt.map(isFresh) ?? false
        state.suggestedMove = session.phase == .recommendation ? suggestedMove : nil
        if let recognizedBoardAtBottom { state.boardAtBottom = recognizedBoardAtBottom }
        if recommendation != state.move { recommendation = state.move }
        if recommendationDetail != state.detail { recommendationDetail = state.detail }
        pipController.update(state)
        writeDiagnostics()
    }
}

/// 取消状态会跨 MainActor 与引擎队列读取；只阻止尚未开始的陈旧任务，不并发访问引擎实例。
private final class AnalysisTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
