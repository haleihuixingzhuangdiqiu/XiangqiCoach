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
    /// 仅传入已确认的实际局面；尚未识别时保持 nil，避免把示例棋盘当成实时结果。
    var position: XiangqiPosition? = nil
    var suggestedMove: XiangqiMove? = nil
    var boardAtBottom: Side = .red
    /// false 时保留上次确认棋盘供查看，但不可据此显示实时落子指令。
    var boardIsCurrent = true
}

@MainActor
final class PiPCoachController: NSObject, ObservableObject {
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var errorMessage: String?

    private weak var displayView: CoachSampleBufferView?
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private(set) var state = CoachOverlayState()
    private let frameFactory = OverlayFrameFactory()

    override init() {
        super.init()
        configureAudioSession()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderCurrentState() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit {
        timer?.invalidate()
    }

    func attach(to view: CoachSampleBufferView) {
        displayView = view
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
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
        renderCurrentState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.isPictureInPicturePossible = controller.isPictureInPicturePossible
        }
    }

    func update(_ newState: CoachOverlayState) {
        guard state != newState else { return }
        state = newState
        renderCurrentState()
    }

    func start() {
        guard let controller else {
            errorMessage = "悬浮窗口还没有准备好"
            return
        }
        guard controller.isPictureInPicturePossible else {
            errorMessage = "画中画暂不可用。请确认已在真机开启“音频、AirPlay 与画中画”能力"
            return
        }
        renderCurrentState()
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
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
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        if let sampleBuffer = frameFactory.makeSampleBuffer(state: state) {
            layer.enqueue(sampleBuffer)
        }
        let isPossible = controller?.isPictureInPicturePossible ?? false
        if isPictureInPicturePossible != isPossible {
            DispatchQueue.main.async { [weak self] in
                self?.isPictureInPicturePossible = isPossible
            }
        }
    }
}

extension PiPCoachController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = true
        errorMessage = nil
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        errorMessage = "无法开启悬浮指导：\(error.localizedDescription)"
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
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

final class OverlayFrameFactory {
    private var cachedState: CoachOverlayState?
    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedFormat: CMVideoFormatDescription?

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