import Foundation
import ImageIO
import Network

final class FrameReceiver {
    static let port: NWEndpoint.Port = 43_981

    var onFrame: ((CGImage, TimeInterval) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.lgj.xiangqicoach.frame-receiver", qos: .userInitiated)
    private var listener: NWListener?
    private let requestedPort: NWEndpoint.Port
    var listeningPort: NWEndpoint.Port? { listener?.port }

    init(port: NWEndpoint.Port = FrameReceiver.port) { requestedPort = port }
    private var freshness = FrameFreshnessGate()

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
            // 地址和端口已由本地端点指定；再次传 on: 固定端口会让 Network.framework 抛 EINVAL。
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.receiveFrame(from: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus?("录屏接收器已就绪")
                case let .failed(error):
                    self?.onStatus?("录屏接收器失败：\(error.localizedDescription)")
                    self?.listener = nil
                case .cancelled:
                    self?.listener = nil
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onStatus?("无法启动本机画面接收器：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receiveFrame(from connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) { [weak connection] in connection?.cancel() }
        connection.receive(minimumIncompleteLength: FramePacketHeader.byteCount, maximumLength: FramePacketHeader.byteCount) { [weak self] data, _, _, error in
            guard
                error == nil,
                let data,
                let header = FramePacketHeader(data: data),
                let self,
                self.freshness.isAcceptable(capturedAt: header.capturedAt, now: ProcessInfo.processInfo.systemUptime)
            else {
                connection.cancel()
                return
            }
            self.receiveBody(from: connection, remaining: header.payloadSize, collected: Data(), capturedAt: header.capturedAt)
        }
    }

    private func receiveBody(from connection: NWConnection, remaining: Int, collected: Data, capturedAt: TimeInterval) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard error == nil else {
                connection.cancel()
                return
            }
            var next = collected
            if let data { next.append(data) }
            let bytesLeft = remaining - (data?.count ?? 0)
            if bytesLeft > 0, !isComplete {
                self?.receiveBody(from: connection, remaining: bytesLeft, collected: next, capturedAt: capturedAt)
                return
            }
            connection.cancel()
            guard
                bytesLeft == 0,
                let self,
                self.freshness.isAcceptable(capturedAt: capturedAt, now: ProcessInfo.processInfo.systemUptime),
                let source = CGImageSourceCreateWithData(next as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return
            }
            guard self.freshness.accept(capturedAt: capturedAt, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.onFrame?(image, capturedAt)
        }
    }
}

