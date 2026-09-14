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
    private var admission = FrameAdmission()
    private var captureGeneration = 0
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    func offer(_ sampleBuffer: CMSampleBuffer) {
        let capturedAt = ProcessInfo.processInfo.systemUptime
        admissionLock.lock()
        let accepted = admission.begin(at: capturedAt)
        let generation = captureGeneration
        admissionLock.unlock()
        guard accepted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.admissionLock.lock()
                self.admission.complete()
                self.admissionLock.unlock()
            }
            guard self.activeConnections.isEmpty else { return }
            guard let data = self.jpegData(from: sampleBuffer) else { return }
            self.admissionLock.lock()
            let isActive = self.admission.isActive && self.captureGeneration == generation
            self.admissionLock.unlock()
            guard isActive, ProcessInfo.processInfo.systemUptime - capturedAt < 0.5 else { return }
            self.send(data, capturedAt: capturedAt)
        }
    }

    func setActive(_ active: Bool) {
        admissionLock.lock()
        captureGeneration += 1
        admission.setActive(active)
        admissionLock.unlock()
        guard !active else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for identifier in Array(self.activeConnections.keys) { self.finishConnection(identifier) }
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

    private func send(_ imageData: Data, capturedAt: TimeInterval) {
        guard (1...FramePacketHeader.maximumPayloadSize).contains(imageData.count) else { return }
        var packet = FramePacketHeader(payloadSize: imageData.count, capturedAt: capturedAt).data
        packet.append(imageData)

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let identifier = ObjectIdentifier(connection)
        activeConnections[identifier] = connection
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
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishConnection(identifier)
        }
    }

    private func finishConnection(_ identifier: ObjectIdentifier) {
        guard let connection = activeConnections.removeValue(forKey: identifier) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
