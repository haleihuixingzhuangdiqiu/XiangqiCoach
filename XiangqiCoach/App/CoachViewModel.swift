import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class CoachViewModel: ObservableObject {
    @Published private(set) var turnStatus = "等待棋盘"

    @Published private(set) var isRecognizerReady = false
    @Published private(set) var recognitionPreparationStatus = "正在准备棋盘识别…"
    @Published private(set) var captureStatus = "等待系统录屏"
    @Published private(set) var recognitionStatus = "尚未收到画面"
    @Published private(set) var latencyStatus = "等待录屏画面"
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
    private var recognitionFrames = LatestRecognitionFrame<CGImage>()
    private var totalReceivedFrames = 0
    private var lastDiagnosticsUIAt = -Double.infinity
    private var boardTracker = BoardTracker()
    private var currentPosition: XiangqiPosition? { boardTracker.position }
    private var suggestedMove: XiangqiMove?
    private var moveRecall = CoachMoveRecallState()
    private var analysisState = CoachAnalysisState()
    private var analysisTicket: AnalysisTicket?
    private var engineFailureMessage: String?
    private var didAnnounceRecommendation = false

    private var recognizerGeneration = 0
    private var session = CoachSessionState()
    private var captureObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var guidanceRequested = false
    /// 一段录屏只自动请求一次；用户关闭浮窗后不会被后续每一帧重新拉起。
    private var didRequestPiPForCapture = false
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
    private var requiresMoveEvidence = false
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
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateCaptureState(UIScreen.main.isCaptured)
                if self.isScreenCaptured, self.guidanceRequested { self.requestPiPIfNeeded() }
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
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        freshnessTimer?.invalidate()
    }

    var startupStatus: String {
        if !isRecognizerReady { return recognitionPreparationStatus }
        if !isScreenCaptured { return "准备就绪" }
        return session.hasReceivedFrame ? "已就绪，切回天天象棋" : "正在连接录屏画面"
    }

    /// 原生录屏按钮的同一次点击先准备应用，录屏权限仍由系统面板确认。
    func prepareToStart() {
        updateCaptureState(UIScreen.main.isCaptured)
        guidanceRequested = true
        receiver.start()
        if session.preparationFailed { prepareRecognizer() }
        if isScreenCaptured { requestPiPIfNeeded() }
    }

    /// 当前录屏保持不变，仅恢复用户关闭或未能开启的悬浮指导。
    func resumeGuidance() {
        didRequestPiPForCapture = false
        prepareToStart()
        if analysisState.hasFailure { invalidateAnalysis() }
    }

    private func requestPiPIfNeeded() {
        guard isScreenCaptured, !didRequestPiPForCapture else { return }
        didRequestPiPForCapture = true
        updateOverlay()
        pipController.start()
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
        totalReceivedFrames += 1
        updateLatency(capturedAt: capturedAt)
        guard isFresh(capturedAt), capturedAt > (lastFrameCapturedAt ?? 0) else {
            checkFrameFreshness()
            return
        }
        lastFrameCapturedAt = capturedAt
        // 首帧来自本扩展；即使 App 打开前已录屏，或通知先后顺序变化，也补齐自动启动。
        requestPiPIfNeeded()
        if captureStatus != "录屏中 · 已收到画面" { captureStatus = "录屏中 · 已收到画面" }
        guard let recognizer else {
            recognitionStatus = recognitionPreparationStatus
            return
        }
        guard let work = recognitionFrames.offer(image, capturedAt: capturedAt) else { return }
        recognize(work, using: recognizer)
    }

    /// 识别串行运行，忙时只留一个最新待处理帧；完成即续跑，不额外等待下一次录屏回调。
    private func recognize(_ work: LatestRecognitionFrame<CGImage>.Work, using recognizer: BoardRecognizer) {
        let image = work.value
        let capturedAt = work.capturedAt
        let sideToMove = currentPosition?.sideToMove ?? .red
        let sessionGeneration = session.generation
        recognitionQueue.async { [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = Result { try recognizer.recognize(image, sideToMove: sideToMove) }
            let recognitionMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.session.acceptsResult(from: sessionGeneration), self.recognitionFrames.isCurrent(work) else { return }
                defer {
                    if let next = self.recognitionFrames.complete(work, now: ProcessInfo.processInfo.systemUptime) {
                        self.recognize(next, using: recognizer)
                    }
                }
                self.lastRecognitionMilliseconds = recognitionMilliseconds
                self.updateLatency(capturedAt: capturedAt)
                guard self.isFresh(capturedAt) else {
                    self.boardTracker.loseBoard()
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
        let observation = boardTracker.observe(recognition.position, lastMove: recognition.lastMove)
        switch observation {
        case .confirming:
            recognitionStatus = "正在确认局面…"
            showRecognitionWait(.confirmingBoard)
        case .waitingForMoveEvidence:
            _ = confirmObservedSide(recognition.boardAtBottom)
            turnStatus = "正在识别上一步标记"
            recognitionStatus = "正在自动确认轮次"
            showRecognitionWait(.confirmingBoard, detail: "正在读取上一步起点与落点，保持完整棋盘可见即可", requiresEvidence: true)
        case let .unchanged(position):
            turnStatus = "\(position.sideToMove.displayName)走 · 自动识别"
            guard confirmObservedSide(recognition.boardAtBottom) else {
                showRecognitionWait(.confirmingBoard, detail: "正在确认棋盘朝向，请保持画面稳定")
                return
            }
            lastConfirmedFrameAt = capturedAt
            recognitionStatus = "局面稳定 · \(recognition.qualityText)"
            analyzeIfNeeded(position)
        case let .accepted(position, reason):
            switch reason {
            case .takeback, .restoredHistory:
                // 悔棋恢复了不同的实际历史；旧 FEN 的排队任务、回看和播报均不能复用。
                invalidateAnalysis()
            case .newGame, .legalMoves, .lastMoveMarker:
                break
            }
            // 已证明实际走子后立即删除原记录，即使仍需确认朝向也不能套用旧走法。
            moveRecall.confirm(position: position, boardAtBottom: recognition.boardAtBottom)
            speech.stopSpeaking(at: .immediate)
            turnStatus = "\(position.sideToMove.displayName)走 · 自动识别"
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
            case let .takeback(count):
                recognitionStatus = "已同步悔棋\(count)步 · \(position.sideToMove.displayName)走"
            case .restoredHistory:
                recognitionStatus = "已恢复悔棋前局面 · \(position.sideToMove.displayName)走"
            case .lastMoveMarker:
                recognitionStatus = "已根据上一步自动同步 · \(position.sideToMove.displayName)走"
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
        requiresMoveEvidence = false

        guard recognizedBoardAtBottom != nil else { return }
        // 双方回合都分析；执棋方只影响展示身份与语音，不能阻止对手走法计算。
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
                    // 结果已缓存，等同局面重获确认再发布；不能用旧结果强制改变遮挡/轮次确认提示。
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
        if let recognizedBoardAtBottom {
            moveRecall.remember(result.move, in: position, boardAtBottom: recognizedBoardAtBottom)
        }
        let scoreText = String(format: "%+.2f", Double(result.score) / 100)
        recommendation = notation
        recommendationDetail = "\(result.move.iccs()) · 深度 \(result.depth) · 评分 \(scoreText)"
        session.advance(to: .recommendation, generation: session.generation)
        updateOverlay()

        if position.sideToMove == recognizedBoardAtBottom, !didAnnounceRecommendation {
            didAnnounceRecommendation = true
            speech.stopSpeaking(at: .word)
            let utterance = AVSpeechUtterance(string: notation)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.46
            speech.speak(utterance)
        }
    }

    private func updateCaptureState(_ captured: Bool) {
        if isScreenCaptured != captured { isScreenCaptured = captured }
        guard session.setCaptureActive(captured) else { return }
        resetRecognition()
        didRequestPiPForCapture = false
        if !captured {
            guidanceRequested = false
            pipController.stop()
        }
        captureStatus = captured ? "系统录屏已开启" : "录屏已停止"
        recognitionStatus = captured ? "等待录屏画面" : "识别已暂停"
        updateOverlay()
        if captured, guidanceRequested { requestPiPIfNeeded() }
    }

    private func resetRecognition() {
        invalidateAnalysis()
        recognitionFrames.reset()
        turnStatus = "等待棋盘"
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

    /// 只有明确换局、改方向、停止或重新准备识别才使计算失效，短暂识别失败不走此入口。
    private func invalidateAnalysis() {
        engine.cancel()
        analysisTicket?.cancel()
        analysisTicket = nil
        analysisState.reset()
        moveRecall.reset()
        engineFailureMessage = nil
        didAnnounceRecommendation = false
        suggestedMove = nil
        speech.stopSpeaking(at: .immediate)
    }

    private func showRecognitionWait(
        _ phase: CoachSessionState.Phase,
        detail: String = "请打开指定的对局棋盘，并露出全部棋子",
        requiresEvidence: Bool = false
    ) {
        // 画面暂不可信只撤销当前指引，保留原局面及明确标注的“上一条走法”，同局计算继续。
        // 必须清确认时间，防止回看或刚完成的搜索被误当成最新画面的有效建议。
        lastConfirmedFrameAt = nil
        suggestedMove = nil
        recognitionWaitDetail = detail
        requiresMoveEvidence = requiresEvidence
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
        // 诊断页面每秒最多更新两次；后台仍记录真实计数和耗时，不为每帧重建整页视图。
        let now = ProcessInfo.processInfo.systemUptime
        if UIApplication.shared.applicationState == .active, now - lastDiagnosticsUIAt >= 0.5 {
            lastDiagnosticsUIAt = now
            receivedFrameCount = totalReceivedFrames
            let recognition = lastRecognitionMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
            let engine = lastEngineMilliseconds.map { "\($0) ms" } ?? "—"
            latencyStatus = String(format: "画面 %.0f ms · 识别 %@ · 计算 %@", frameMilliseconds, recognition, engine)
        }
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        let confirmedFEN: String?
        switch session.phase {
        case .analyzing, .recommendation, .finished:
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
            receivedFrameCount: totalReceivedFrames,
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
            state = CoachOverlayState(title: "已收到录屏画面", move: requiresMoveEvidence ? "正在识别轮次…" : "正在确认局面…",
                                      detail: recognitionWaitDetail, accent: .systemYellow)
        case .analyzing:
            state = CoachOverlayState(title: "\(currentPosition?.sideToMove.displayName ?? "棋局") · 正在分析", move: "计算中…", detail: "请稍候", accent: .systemYellow)
        case .recommendation:
            let isOpponent = currentPosition?.sideToMove != recognizedBoardAtBottom
            state = CoachOverlayState(title: isOpponent ? "对手走法 · 仅图形提示" : "我方走法", move: recommendation,
                                      detail: recommendationDetail, accent: isOpponent ? .systemBlue : .systemGreen)
        case .finished:
            state = CoachOverlayState(title: engineFailureMessage == nil ? "分析完成" : "计算失败", move: recommendation,
                                      detail: recommendationDetail, accent: .systemRed)
        case .recordingStopped:
            state = CoachOverlayState(title: "录屏已停止", move: "指导已暂停", detail: "返回教练重新开启“棋研录屏”", accent: .systemOrange)
        }
        state.showsStartScreen = !session.isCapturing
        // 棋盘是独立于搜索状态的持久内容；等待识别/思考不再把整个浮窗切成白底。
        state.position = session.isCapturing && recognizedBoardAtBottom != nil ? currentPosition : nil
        state.boardIsCurrent = lastConfirmedFrameAt.map(isFresh) ?? false
        state.suggestedMove = session.phase == .recommendation ? suggestedMove : nil
        if let recognizedBoardAtBottom { state.boardAtBottom = recognizedBoardAtBottom }
        state.previousSuggestion = moveRecall.previousSuggestion(
            for: state.position, boardAtBottom: recognizedBoardAtBottom,
            hasCurrentSuggestion: state.boardIsCurrent && state.suggestedMove != nil
        )
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
