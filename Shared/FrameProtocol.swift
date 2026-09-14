import Foundation

/// 主应用与扩展共用带采集时间的帧头；单调时钟在同一设备的两个进程间保持一致。
struct FramePacketHeader {
    static let byteCount = 16
    static let maximumPayloadSize = 1_500_000
    let payloadSize: Int
    let capturedAt: TimeInterval

    var data: Data {
        var result = Data([0x51, 0x43, 0x46, 0x32])
        var length = UInt32(payloadSize).bigEndian
        var timestamp = capturedAt.bitPattern.bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }
        return result
    }

    init(payloadSize: Int, capturedAt: TimeInterval) {
        self.payloadSize = payloadSize
        self.capturedAt = capturedAt
    }

    init?(data: Data) {
        guard data.count == Self.byteCount, data.prefix(4) == Data([0x51, 0x43, 0x46, 0x32]) else { return nil }
        let bytes = Array(data)
        let length = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let timestamp = Double(bitPattern: bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        guard (1...Self.maximumPayloadSize).contains(Int(length)), timestamp.isFinite, timestamp > 0 else { return nil }
        payloadSize = Int(length)
        capturedAt = timestamp
    }
}

/// 在进入编码队列之前限频，忙时直接丢帧，避免排队持有大量旧的 ReplayKit 像素缓冲。
struct FrameAdmission {
    static let minimumInterval: TimeInterval = 1.0 / 6.0
    private(set) var isActive = true
    private var isBusy = false
    private var lastAcceptedAt = -Double.infinity

    mutating func begin(at now: TimeInterval) -> Bool {
        guard isActive, !isBusy, now - lastAcceptedAt >= Self.minimumInterval else { return false }
        isBusy = true
        lastAcceptedAt = now
        return true
    }

    mutating func complete() { isBusy = false }
    mutating func setActive(_ active: Bool) {
        isActive = active
        if active { lastAcceptedAt = -Double.infinity }
    }
}

/// 跨连接乱序或积压的旧画面不得让局面倒退；迟到超过一秒时等待下一张新画面。
struct FrameFreshnessGate {
    private var latestTimestamp = -Double.infinity

    mutating func accept(capturedAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - capturedAt
        guard age >= 0, age <= 1, capturedAt > latestTimestamp else { return false }
        latestTimestamp = capturedAt
        return true
    }
}
