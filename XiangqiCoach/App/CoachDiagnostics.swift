import Foundation

/// 真机本地诊断仅记录流水线状态与棋局，禁止加入录屏图像、头像或其他屏幕内容。
struct CoachDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let phase: String
    let displayedFEN: String?
    let boardIsCurrent: Bool
    let isAnalyzing: Bool
    let isScreenCaptured: Bool
    let broadcastConnectionState: String
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

/// 变化最多每秒提交一次；静止状态每十秒刷新存活时间，区分零帧与应用被挂起。
/// 当前快照另附最多 120 条状态变化，保留复发前后的本地证据；不记录录屏图像，写入离开主线程。
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

                // 帧数/耗时持续变化不会追加事件；仅保存阶段、连接、识别错误和已确认局面的变化。
                // 跨启动读取同一有界文件，让回到前台或覆盖安装后仍能追查此前中断。
                let historyURL = destination.deletingLastPathComponent().appendingPathComponent("coach-diagnostics-history.json")
                let historyData = try? Data(contentsOf: historyURL)
                var history = historyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
                let stateKeys = ["sessionIdentifier", "phase", "captureStatus", "receiverStatus", "recognitionStatus",
                                 "broadcastConnectionState", "confirmedFEN", "pictureInPictureError", "engineError",
                                 "applicationState", "isScreenCaptured", "isPictureInPictureActive", "isPictureInPicturePossible"]
                let changed = history.last.map { previous in
                    stateKeys.contains { (previous[$0] as? NSObject) != (payload[$0] as? NSObject) }
                } ?? true
                if changed {
                    history = Array(history.suffix(119))
                    history.append(payload)
                    let historyData = try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
                    try historyData.write(to: historyURL, options: .atomic)
                }
            } catch {
                // 本地诊断属于可选旁路；写入失败不得打断录屏或棋局分析，当前可用文件保持不变。
            }
        }
    }
}
