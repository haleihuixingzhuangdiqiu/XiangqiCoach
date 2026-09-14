import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import XCTest
@testable import XiangqiCoach

final class FrameReceiverTests: XCTestCase {
    func testExplicitFixedPortReceivesJPEGOverLoopback() async throws {
        // 宿主 App 使用 43981；相邻的非零固定端口走完全相同的生产绑定路径。
        // 旧实现对所有非零固定端口都同步抛 EINVAL，而 .any 不会触发。
        let receiver = FrameReceiver(port: 43_982)
        defer { receiver.stop() }
        let port = try await start(receiver)
        XCTAssertEqual(port, NWEndpoint.Port(rawValue: 43_982))
        let jpeg = try makeJPEG()
        let frame = expectation(description: "固定端口实际 TCP 帧解码完成")
        let observations = ReceivedFrames()
        receiver.onFrame = { image, timestamp in
            observations.append(image, timestamp)
            frame.fulfill()
        }
        let capturedAt = ProcessInfo.processInfo.systemUptime
        try await transmit(packet(jpeg, at: capturedAt), to: 43_982)
        await fulfillment(of: [frame], timeout: 2)
        let received = try XCTUnwrap(observations.snapshot.first)
        XCTAssertEqual(observations.snapshot.count, 1)
        XCTAssertEqual(received.timestamp, capturedAt)
        XCTAssertEqual(received.image.width, 18)
        XCTAssertEqual(received.image.height, 12)
    }

    func testFragmentedHeaderAndJPEGReachRealLoopbackReceiverWithOriginalTimestamp() async throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        let port = try await start(receiver)
        let jpeg = try makeJPEG()
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let frame = expectation(description: "实际 TCP 帧解码完成")
        let observations = ReceivedFrames()
        receiver.onFrame = { image, timestamp in
            observations.append(image, timestamp)
            frame.fulfill()
        }
        let header = FramePacketHeader(payloadSize: jpeg.count, capturedAt: capturedAt).data
        let fragments = [Data(header.prefix(3)), Data(header[3..<8]), Data(header.suffix(8)),
                         Data(jpeg.prefix(11)), Data(jpeg[11..<29]), Data(jpeg.dropFirst(29))]
        try await transmit(fragments, to: port)
        await fulfillment(of: [frame], timeout: 2)
        let received = try XCTUnwrap(observations.snapshot.first)
        XCTAssertEqual(observations.snapshot.count, 1)
        XCTAssertEqual(received.timestamp, capturedAt)
        XCTAssertEqual(received.image.width, 18)
        XCTAssertEqual(received.image.height, 12)
        let pixel = try firstPixel(received.image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let expected = try firstPixel(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        XCTAssertEqual(pixel, expected)
    }

    func testRealConnectionsDropStaleOutOfOrderAndMalformedFramesThenContinueReceiving() async throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        let port = try await start(receiver)
        let jpeg = try makeJPEG()
        let first = expectation(description: "新帧建立时间基准")
        let second = expectation(description: "拒绝异常包后仍收到下一张新帧")
        let observations = ReceivedFrames()
        receiver.onFrame = { image, timestamp in
            let count = observations.append(image, timestamp)
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
            if count > 2 { XCTFail("旧帧或畸形包不应进入识别回调") }
        }
        let firstTimestamp = ProcessInfo.processInfo.systemUptime
        try await transmit(packet(jpeg, at: firstTimestamp), to: port)
        await fulfillment(of: [first], timeout: 2)

        var wrongMagic = FramePacketHeader(payloadSize: jpeg.count, capturedAt: firstTimestamp).data
        wrongMagic[0] = 0
        let rejected: [[Data]] = [
            packet(jpeg, at: firstTimestamp - 2),
            packet(jpeg, at: firstTimestamp - 0.01),
            packet(jpeg, at: firstTimestamp),
            [wrongMagic, jpeg],
            [FramePacketHeader(payloadSize: 0, capturedAt: firstTimestamp).data],
            [FramePacketHeader(payloadSize: 1_500_001, capturedAt: firstTimestamp).data],
            [FramePacketHeader(payloadSize: jpeg.count, capturedAt: .nan).data, jpeg],
            [Data(FramePacketHeader(payloadSize: jpeg.count, capturedAt: firstTimestamp).data.prefix(7))],
            [FramePacketHeader(payloadSize: jpeg.count, capturedAt: firstTimestamp).data, Data(jpeg.prefix(5))],
            [FramePacketHeader(payloadSize: 4, capturedAt: firstTimestamp).data, Data([1, 2, 3, 4])],
        ]
        // 每个连接等接收器关闭后再发下一个，拒绝路径也有真实网络完成事件，不用固定延时猜测。
        for fragments in rejected { try await transmit(fragments, to: port) }
        let secondTimestamp = ProcessInfo.processInfo.systemUptime
        try await transmit(packet(jpeg, at: secondTimestamp), to: port)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(observations.snapshot.map(\.timestamp), [firstTimestamp, secondTimestamp])
        XCTAssertTrue(observations.snapshot.allSatisfy { $0.image.width == 18 && $0.image.height == 12 })
    }

    private func start(_ receiver: FrameReceiver) async throws -> NWEndpoint.Port {
        let ready = expectation(description: "NWListener ready")
        receiver.onStatus = { status in
            if status == "录屏接收器已就绪" { ready.fulfill() }
            if status.contains("失败") || status.contains("无法启动") { XCTFail(status) }
        }
        receiver.start()
        await fulfillment(of: [ready], timeout: 2)
        return try XCTUnwrap(receiver.listeningPort)
    }

    private func packet(_ jpeg: Data, at timestamp: TimeInterval) -> [Data] {
        [FramePacketHeader(payloadSize: jpeg.count, capturedAt: timestamp).data, jpeg]
    }

    private func transmit(_ fragments: [Data], to port: NWEndpoint.Port) async throws {
        let transmission = LoopbackTransmission(port: port, fragments: fragments)
        try await withCheckedThrowingContinuation { continuation in
            transmission.start { continuation.resume(with: $0) }
        }
    }

    private func makeJPEG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 18, height: 12, bitsPerComponent: 8, bytesPerRow: 18 * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 18, height: 12))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func firstPixel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [bytes[0], bytes[1], bytes[2]]
    }
}

private final class ReceivedFrames: @unchecked Sendable {
    struct Frame {
        let image: CGImage
        let timestamp: TimeInterval
    }
    private let lock = NSLock()
    private var frames: [Frame] = []

    @discardableResult
    func append(_ image: CGImage, _ timestamp: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }
        frames.append(Frame(image: image, timestamp: timestamp))
        return frames.count
    }

    var snapshot: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

/// 真实 TCP 客户端逐段发送；服务器 EOF/RST 是处理完成屏障，避免用 sleep 判定拒绝。
private final class LoopbackTransmission {
    private let connection: NWConnection
    private let fragments: [Data]
    private let queue = DispatchQueue(label: "com.lgj.xiangqicoach.tests.loopback")
    private var connected = false
    private var completion: ((Result<Void, Error>) -> Void)?

    init(port: NWEndpoint.Port, fragments: [Data]) {
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.fragments = fragments
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connected = true
                self.receiveClose()
                self.sendFragment(0)
            case let .failed(error):
                self.finish(self.connected ? .success(()) : .failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finish(.failure(NSError(domain: "FrameReceiverTests", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "接收器没有关闭测试连接"])))
        }
    }

    private func sendFragment(_ index: Int) {
        guard completion != nil, fragments.indices.contains(index) else { return }
        connection.send(content: fragments[index], isComplete: index == fragments.count - 1, completion: .contentProcessed { error in
            // 非法帧头允许服务器在 body 发送之前关闭连接。
            if error == nil { self.sendFragment(index + 1) }
        })
    }

    private func receiveClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            if complete || error != nil { self.finish(.success(())) }
            else { self.receiveClose() }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}