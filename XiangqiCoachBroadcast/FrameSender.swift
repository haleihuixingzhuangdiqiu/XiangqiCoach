import CoreImage
import Foundation
import ImageIO
import Network
import ReplayKit

final class FrameSender {
    private let port: NWEndpoint.Port = 43_981
    private let queue = DispatchQueue(label: "com.lgj.xiangqicoach.broadcast-sender", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let admissionLock = NSLock()
    private var admission = FrameAdmission<CMSampleBuffer>()
    private var activeConnections: [UUID: (connection: NWConnection, generation: Int)] = [:]

    func offer(_ sampleBuffer: CMSampleBuffer) {
        admissionLock.lock()
        if let generation = admission.offer(sampleBuffer, capturedAt: ProcessInfo.processInfo.systemUptime) {
            queue.async { [weak self] in self?.drainLatestFrame(generation: generation) }
        }
        admissionLock.unlock()
    }

    func setActive(_ active: Bool) {
        admissionLock.lock()
        admission.setActive(active)
        queue.async { [weak self] in
            guard let self else { return }
            for identifier in Array(self.activeConnections.keys) { self.finishConnection(identifier) }
        }
        admissionLock.unlock()
    }

    /// 同时至多一张正在编码/发送、一张待处理；限频等待和网络等待期间都可替换待处理截图。
    private func drainLatestFrame(generation: Int) {
        admissionLock.lock()
        let next = admission.next(generation: generation, at: ProcessInfo.processInfo.systemUptime)
        admissionLock.unlock()
        switch next {
        case .idle:
            return
        case let .wait(delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.drainLatestFrame(generation: generation)
            }
        case let .frame(frame):
            let data = autoreleasepool { jpegData(from: frame.payload) }
            admissionLock.lock()
            let isActive = admission.isActive && admission.generation == frame.generation
            admissionLock.unlock()
            if let data, isActive,
               ProcessInfo.processInfo.systemUptime - frame.capturedAt < FrameAdmission<CMSampleBuffer>.maximumSendAge,
               send(data, capturedAt: frame.capturedAt, generation: generation) {
                // 网络完成/超时负责继续消费最新帧；期间 offer 不会再投递编码工作。
                return
            }
            queue.async { [weak self] in self?.drainLatestFrame(generation: generation) }
        }
    }

    private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        if
            let attachment = CMGetAttachment(
                sampleBuffer,
                key: RPVideoSampleOrientationKey as CFString,
                attachmentModeOut: nil
            ) as? NSNumber,
            let orientation = CGImagePropertyOrientation(rawValue: UInt32(attachment.uintValue))
        {
            image = image.oriented(orientation)
        }

        let extent = image.extent
        let scale = min(1, 720 / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        return context.jpegRepresentation(
            of: translated,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]
        )
    }

    private func send(_ imageData: Data, capturedAt: TimeInterval, generation: Int) -> Bool {
        guard (1...FramePacketHeader.maximumPayloadSize).contains(imageData.count) else { return false }
        var packet = FramePacketHeader(payloadSize: imageData.count, capturedAt: capturedAt).data
        packet.append(imageData)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: nil, tcp: tcp))
        // 使用独立传输 ID；对象地址可能被复用，旧超时不能误伤后来的连接。
        let identifier = UUID()
        activeConnections[identifier] = (connection, generation)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                    self?.finishConnection(identifier)
                })
            case .failed, .cancelled:
                self.finishConnection(identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // 本机连接故障不能占住发送槽两秒；超时后直接取等待期间最新的截图。
        queue.asyncAfter(deadline: .now() + FrameAdmission<CMSampleBuffer>.maximumSendAge) { [weak self] in
            self?.finishConnection(identifier)
        }
        return true
    }

    private func finishConnection(_ identifier: UUID) {
        guard let transfer = activeConnections.removeValue(forKey: identifier) else { return }
        transfer.connection.stateUpdateHandler = nil
        transfer.connection.cancel()
        queue.async { [weak self] in self?.drainLatestFrame(generation: transfer.generation) }
    }
}
