import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

struct CoachOverlayState: Equatable, Sendable {
    var title = "等待棋盘"
    var move = "请先开始录屏"
    var detail = "识别只在本机进行"
    var accent = UIColor.systemGreen
    /// 首页待机画面保持纯白，真实显示层仍挂载；只有录屏后才绘制指导内容。
    var showsStartScreen = false
    /// 仅传入已确认的实际局面；尚未识别时保持 nil，避免把示例棋盘当成实时结果。
    var position: XiangqiPosition? = nil
    var suggestedMove: XiangqiMove? = nil
    var boardAtBottom: Side = .red
    /// false 时保留上次确认棋盘供查看，但不可据此显示实时落子指令。
    var boardIsCurrent = true
    /// 短暂选子/识别等待期间保留的上一条走法；只供回看，不能替代当前有效建议。
    var previousSuggestion: CoachMoveRecall? = nil
}

@MainActor
final class PiPCoachController: NSObject, ObservableObject {
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var errorMessage: String?

    private weak var displayView: CoachSampleBufferView?
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var readinessObservation: NSKeyValueObservation?
    private var foregroundObserver: NSObjectProtocol?
    private var startup = PiPStartState()
    private(set) var state = CoachOverlayState()
    private let frameFactory = OverlayFrameFactory()

    /// 用户关闭或启动失败后只能显式恢复，首页不能继续伪装成自动准备中。
    var needsExplicitResume: Bool { startup.phase == .stopped || startup.phase == .failed }

    override init() {
        super.init()
        configureAudioSession()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderCurrentState() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.attemptPendingStart() }
        }
    }

    deinit {
        timer?.invalidate()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    func attach(to view: CoachSampleBufferView) {
        guard displayView !== view || controller == nil else { return }
        startup.replaceSource(now: ProcessInfo.processInfo.systemUptime)
        readinessObservation?.invalidate()
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        displayView = view
        // attach 在 SwiftUI 更新中调用；旧 active 状态也只能在新来源确认后异步发布。
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.displayView === view else { return }
            self.isPictureInPictureActive = self.controller?.isPictureInPictureActive == true
            self.isPictureInPicturePossible = self.controller?.isPictureInPicturePossible == true
        }
        view.displayLayer.videoGravity = .resizeAspect
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            // attach 由 SwiftUI 的 makeUIView 触发，延后一拍发布状态，避免在视图更新过程中修改 ObservableObject。
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "当前设备不支持画中画；请用真机验证"
            }
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: view.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = startup.wantsStart
        self.controller = controller
        // 系统就绪时间不固定，不再用一次性的延时猜测；旧来源的回调不得改写新来源。
        readinessObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] source, _ in
            Task { @MainActor in
                guard let self, self.controller === source else { return }
                self.isPictureInPicturePossible = source.isPictureInPicturePossible
                self.attemptPendingStart()
            }
        }
        renderCurrentState()
    }

    func update(_ newState: CoachOverlayState) {
        guard state != newState else { return }
        state = newState
        renderCurrentState()
    }

    /// 点击后或录屏确认后登记一次启动请求；就绪晚到时自动接续，重复调用不重启。
    func start() {
        guard !isPictureInPictureActive || startup.isStopping else { return }
        errorMessage = nil
        startup.request(now: ProcessInfo.processInfo.systemUptime)
        controller?.canStartPictureInPictureAutomaticallyFromInline = startup.wantsStart && !startup.isStopping
        configureAudioSession()
        attemptPendingStart()
    }

    func stop() {
        let awaitsCallback = controller?.isPictureInPictureActive == true || startup.phase == .starting || startup.isStopping
        startup.stop(now: ProcessInfo.processInfo.systemUptime, awaitsCallback: awaitsCallback)
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
    }

    private func attemptPendingStart() {
        let action = startup.nextAction(
            isReady: controller?.isPictureInPicturePossible == true,
            isForeground: UIApplication.shared.applicationState == .active,
            now: ProcessInfo.processInfo.systemUptime
        )
        switch action {
        case .start:
            controller?.startPictureInPicture()
        case .timedOut:
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            controller?.stopPictureInPicture()
            // 超时后的旧 controller 不得再把迟到回调归到下一次点击，重建来源身份后由用户重试。
            controller?.delegate = nil
            controller = nil
            if let displayView { attach(to: displayView) }
            errorMessage = "悬浮窗暂未就绪，返回后点继续指导重试"
        case nil:
            break
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            errorMessage = "画中画音频会话初始化失败：\(error.localizedDescription)"
        }
    }

    private func renderCurrentState() {
        guard let layer = displayView?.displayLayer else { return }
        frameFactory.displayLatest(state: state, on: layer)
        attemptPendingStart()
    }
}

extension PiPCoachController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        startup.willStart(now: ProcessInfo.processInfo.systemUptime)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        guard startup.didStart() else {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        isPictureInPictureActive = true
        errorMessage = nil
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard controller === pictureInPictureController else { return }
        if startup.isStopping {
            startup.didStop(now: ProcessInfo.processInfo.systemUptime)
        } else {
            startup.fail()
        }
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = startup.wantsStart
        isPictureInPictureActive = false
        errorMessage = "无法开启悬浮指导：\(error.localizedDescription)"
        attemptPendingStart()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        startup.willStop(now: ProcessInfo.processInfo.systemUptime)
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        startup.didStop(now: ProcessInfo.processInfo.systemUptime)
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = startup.wantsStart
        isPictureInPictureActive = false
        DispatchQueue.main.async { [weak self] in self?.attemptPendingStart() }
    }
}

extension PiPCoachController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        true
    }
}

final class CoachSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

struct CoachPiPPreview: UIViewRepresentable {
    @ObservedObject var controller: PiPCoachController

    func makeUIView(context: Context) -> CoachSampleBufferView {
        let view = CoachSampleBufferView()
        view.backgroundColor = .black
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: CoachSampleBufferView, context: Context) {}
}

/// 把显示队列的背压与像素生成分开，拥塞时仍可立即用最新状态替换过时样本。
protocol OverlayFrameDestination: AnyObject {
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var isReadyForMoreMediaData: Bool { get }
    func flush()
    func enqueue(_ sampleBuffer: CMSampleBuffer)
}

extension AVSampleBufferDisplayLayer: OverlayFrameDestination {}

final class OverlayFrameFactory {
    private var cachedState: CoachOverlayState?
    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedFormat: CMVideoFormatDescription?

    func displayLatest(state: CoachOverlayState, on destination: OverlayFrameDestination) {
        guard let sampleBuffer = makeSampleBuffer(state: state) else { return }
        // 这是实时状态流：满队列时丢弃旧样本，flush 保留正在显示的图像，不等 500 ms 保活重试。
        // Apple 允许实时来源在 !isReady 时 enqueue；先 flush 可避免无界堆积。
        if destination.status == .failed || !destination.isReadyForMoreMediaData { destination.flush() }
        destination.enqueue(sampleBuffer)
    }

    func makeSampleBuffer(state: CoachOverlayState) -> CMSampleBuffer? {
        if cachedState != state || cachedPixelBuffer == nil {
            let image = CoachBoardRenderer.image(for: state)
            guard let buffer = Self.pixelBuffer(from: image, size: CoachBoardRenderer.canvasSize) else { return nil }
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                               imageBuffer: buffer,
                                                               formatDescriptionOut: &format) == noErr else { return nil }
            cachedPixelBuffer = buffer
            cachedFormat = format
            cachedState = state
        }
        guard let pixelBuffer = cachedPixelBuffer, let formatDescription = cachedFormat else { return nil }

        // 使用真实单调时间及逐样本的立即显示标记。状态更新频率不固定，不能用帧数/2累加未来时间戳。
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    private static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ),
            let cgImage = image.cgImage
        else {
            return nil
        }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pixelBuffer
    }
}