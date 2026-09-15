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
        // 时间戳有效但 JPEG 无效时也不能推进门禁；随后同一采集时间的完整图仍须成功。
        try await transmit([FramePacketHeader(payloadSize: 4, capturedAt: secondTimestamp).data,
                            Data([1, 2, 3, 4])], to: port)
        try await transmit(packet(jpeg, at: secondTimestamp), to: port)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(observations.snapshot.map(\.timestamp), [firstTimestamp, secondTimestamp])
        XCTAssertTrue(observations.snapshot.allSatisfy { $0.image.width == 18 && $0.image.height == 12 })
    }

    func testExpiredHeaderClosesBeforeBodyOrConnectionWatchdog() async throws {
        let receiver = FrameReceiver(port: .any)
        defer { receiver.stop() }
        let port = try await start(receiver)
        receiver.onFrame = { _, _ in XCTFail("过期帧头不能进入解码回调") }
        let closed = expectation(description: "只收到过期帧头即可关闭，不等待 JPEG body")
        let header = FramePacketHeader(payloadSize: 1_000_000,
                                       capturedAt: ProcessInfo.processInfo.systemUptime - 2).data
        let transmission = LoopbackTransmission(port: port, fragments: [header])
        transmission.start { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            closed.fulfill()
        }
        // 生产连接看门狗是 1 秒；0.75 秒截止能区别立即拒绝与占住接收槽等待超时。
        await fulfillment(of: [closed], timeout: 0.75)
    }


    func testOccupiedLoopbackPortAutomaticallyRecoversAndReceivesJPEG() async throws {
        let blocker = try await makeBlockingListener()
        defer { blocker.cancel() }
        let port = try XCTUnwrap(blocker.port)
        let receiver = FrameReceiver(port: port)
        defer { receiver.stop() }
        let failed = expectation(description: "真实端口占用触发监听失败")
        let recovered = expectation(description: "释放端口后自动恢复，不再次调用 start")
        receiver.onStatus = { status in
            if status.contains("失败") {
                failed.fulfill()
                blocker.cancel()
            }
            if status == "录屏接收器已就绪" { recovered.fulfill() }
        }
        receiver.start()
        await fulfillment(of: [failed, recovered], timeout: 3, enforceOrder: true)
        XCTAssertEqual(receiver.listeningPort, port)
        try await assertReceivesJPEG(receiver, port: port)
    }

    func testStopCancelsPendingConstructorRetryAndExplicitStartCanRecover() async throws {
        let probe = FrameListenerProbe()
        let receiver = FrameReceiver(port: .any, makeListener: { parameters in
            if probe.recordAttempt() == 1 { throw NWError.posix(.EADDRINUSE) }
            return try NWListener(using: parameters)
        })
        defer { receiver.stop() }
        let failed = expectation(description: "构造失败已通知")
        let unwantedReady = expectation(description: "stop 后不能执行待重试监听")
        unwantedReady.isInverted = true
        receiver.onStatus = { [weak receiver] status in
            if status.contains("无法启动") {
                // 故障通知在接收队列内；stop 必须可重入且取消刚排队的重试。
                receiver?.stop()
                failed.fulfill()
            }
            if status == "录屏接收器已就绪" { unwantedReady.fulfill() }
        }
        receiver.start()
        await fulfillment(of: [failed], timeout: 1)
        await fulfillment(of: [unwantedReady], timeout: 0.6)
        XCTAssertNil(receiver.listeningPort)
        XCTAssertEqual(probe.attemptCount, 1)
        let port = try await start(receiver)
        XCTAssertEqual(probe.attemptCount, 2)
        try await assertReceivesJPEG(receiver, port: port)
    }

    func testConstructorFailureAutomaticallyRetriesWithoutAnotherStartCall() async throws {
        let probe = FrameListenerProbe()
        let receiver = FrameReceiver(port: .any, makeListener: { parameters in
            if probe.recordAttempt() == 1 { throw NWError.posix(.EMFILE) }
            return try NWListener(using: parameters)
        })
        defer { receiver.stop() }
        let failed = expectation(description: "构造错误可观测")
        let ready = expectation(description: "构造失败后自动重试成功")
        receiver.onStatus = { status in
            if status.contains("无法启动") { failed.fulfill() }
            if status == "录屏接收器已就绪" { ready.fulfill() }
        }
        receiver.start()
        await fulfillment(of: [failed, ready], timeout: 2, enforceOrder: true)
        XCTAssertEqual(probe.attemptCount, 2)
        try await assertReceivesJPEG(receiver, port: XCTUnwrap(receiver.listeningPort))
    }

    func testLateOldListenerStatesCannotClearReplacementOrCreateDuplicateListener() async throws {
        let probe = FrameListenerProbe()
        let receiver = FrameReceiver(port: .any, makeListener: { parameters in
            let listener = try NWListener(using: parameters)
            probe.append(listener)
            return listener
        })
        defer { receiver.stop() }
        _ = try await start(receiver)
        let previous = try XCTUnwrap(probe.listeners.first)
        let delayedState = try XCTUnwrap(previous.stateUpdateHandler)
        receiver.stop()
        let ready = expectation(description: "新监听不受旧代失败或取消回调影响")
        receiver.onStatus = { [weak receiver] status in
            guard status == "录屏接收器已就绪", let receiver else { return }
            let replacementPort = receiver.listeningPort
            // 在实际 Network 回调队列重放已经排队的旧事件，精确覆盖 stop/start 竞态。
            delayedState(.failed(.posix(.ECANCELED)))
            delayedState(.cancelled)
            XCTAssertEqual(receiver.listeningPort, replacementPort)
            XCTAssertNotNil(replacementPort)
            receiver.start()
            XCTAssertEqual(probe.listeners.count, 2, "旧事件不能摘除新监听并导致重复创建")
            ready.fulfill()
        }
        receiver.start()
        await fulfillment(of: [ready], timeout: 2)
        try await assertReceivesJPEG(receiver, port: XCTUnwrap(receiver.listeningPort))
    }

    private func makeBlockingListener() async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "真实占端口监听 ready")
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
            if case let .failed(error) = state { XCTFail(error.localizedDescription) }
        }
        listener.start(queue: DispatchQueue(label: "com.lgj.xiangqicoach.tests.port-blocker"))
        await fulfillment(of: [ready], timeout: 2)
        return listener
    }

    private func assertReceivesJPEG(_ receiver: FrameReceiver, port: NWEndpoint.Port) async throws {
        let frame = expectation(description: "恢复后真实 JPEG 可解码")
        let observations = ReceivedFrames()
        receiver.onFrame = { image, timestamp in
            observations.append(image, timestamp)
            frame.fulfill()
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        try await transmit(packet(makeJPEG(), at: timestamp), to: port)
        await fulfillment(of: [frame], timeout: 2)
        let received = try XCTUnwrap(observations.snapshot.first)
        XCTAssertEqual(observations.snapshot.count, 1)
        XCTAssertEqual(received.timestamp, timestamp)
        XCTAssertEqual(received.image.width, 18)
        XCTAssertEqual(received.image.height, 12)
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
/// 实际监听器的线程安全观测，不替换 TCP 连接或 JPEG 解码路径。
private final class FrameListenerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NWListener] = []
    private var attempts = 0

    func append(_ listener: NWListener) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(listener)
    }

    func recordAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        return attempts
    }

    var listeners: [NWListener] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}
