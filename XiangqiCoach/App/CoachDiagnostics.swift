import Foundation

/// 真机本地诊断仅记录流水线状态与棋局，禁止加入录屏图像、头像或其他屏幕内容。
struct CoachDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let phase: String
    let displayedFEN: String?
    let boardIsCurrent: Bool
    let isAnalyzing: Bool
    let isScreenCaptured: Bool
    let receivedFrameCount: Int
    let captureStatus: String
    let receiverStatus: String
    let applicationState: String
    let isPictureInPictureActive: Bool
    let isPictureInPicturePossible: Bool
    let pictureInPictureError: String?
    let recognitionStatus: String
    let frameLatencyMilliseconds: Double?
    let recognitionMilliseconds: Double?
    let engineMilliseconds: Int?
    let confirmedFEN: String?
    let actualSide: Side?
    let engineResultDepth: Int?
    let engineMove: String?
    let engineError: String?
}

/// 变化最多每秒提交一次；静止状态每十秒刷新存活时间，区分零帧与应用被挂起。只覆盖同一文件，写入离开主线程。
@MainActor
final class CoachDiagnostics {
    private let queue = DispatchQueue(label: "com.lgj.xiangqicoach.diagnostics", qos: .utility)
    private let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("coach-diagnostics.json")
    private var lastSubmittedAt = -Double.infinity
    private var lastSnapshot: CoachDiagnosticsSnapshot?
    private let sessionIdentifier = UUID().uuidString
    private let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

    func submit(_ snapshot: CoachDiagnosticsSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSubmittedAt >= 1, snapshot != lastSnapshot || now - lastSubmittedAt >= 10, let destination else { return }
        lastSubmittedAt = now
        lastSnapshot = snapshot
        let sessionIdentifier = sessionIdentifier
        let appBuild = appBuild
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let snapshotData = try encoder.encode(snapshot)
                var payload = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any] ?? [:]
                payload["recordedAt"] = ISO8601DateFormatter().string(from: Date())
                payload["sessionIdentifier"] = sessionIdentifier
                payload["appBuild"] = appBuild
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch {
                // 本地诊断属于可选旁路；写入失败不得打断录屏或棋局分析，也不额外保留日志副本。
            }
        }
    }
}
