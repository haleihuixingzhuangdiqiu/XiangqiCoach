import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CoachViewModel
    @ObservedObject private var pip: PiPCoachController
    @State private var showsHelp = false

    private let ink = Color(red: 0.13, green: 0.17, blue: 0.15)
    private let green = Color(red: 0.10, green: 0.32, blue: 0.25)

    init(model: CoachViewModel) {
        self.model = model
        self.pip = model.pipController
    }

    private var guidanceTitle: String {
        guard model.broadcastConnectionState.canResumeGuidance else {
            return model.broadcastConnectionState == .interrupted ? "重新连接录屏" : "从这里开始"
        }
        if pip.isPictureInPictureActive { return "实时指导中" }
        if pip.errorMessage != nil { return "点继续指导重试" }
        return pip.needsExplicitResume ? "点继续指导恢复" : "正在准备指导"
    }

    private var guidanceStatus: String {
        guard model.broadcastConnectionState.canResumeGuidance else { return model.startupStatus }
        if let error = pip.errorMessage { return error }
        if model.isScreenCaptured, pip.needsExplicitResume { return "录屏仍在运行，悬浮窗已关闭" }
        return model.startupStatus
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("棋研悬浮教练")
                    .font(.headline)
                    .foregroundStyle(ink)
                Spacer()
                Button("使用帮助") { showsHelp = true }
                    .font(.subheadline)
                    .foregroundStyle(green)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("coach.help")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            GeometryReader { geometry in
                let previewWidth = min(max(geometry.size.width - 40, 1), 440)
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    VStack(spacing: 12) {
                        Rectangle()
                            .fill(green)
                            .frame(width: 28, height: 2)
                        Text(guidanceTitle)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(ink)
                        Text(guidanceStatus)
                            .font(.subheadline)
                            .foregroundStyle(model.broadcastConnectionState.canResumeGuidance && pip.errorMessage != nil
                                ? Color(red: 0.67, green: 0.23, blue: 0.17) : Color.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .frame(minHeight: 36)
                            .accessibilityIdentifier("coach.status")
                    }
                    .padding(.horizontal, 24)
                    Spacer(minLength: 12)

                    ZStack {
                        // 这是实际 PiP 来源，始终保持可见、非零尺寸和相同视图身份。
                        // 未录屏时 controller 输出纯白画面；帮助以 sheet 呈现，不移除此来源。
                        CoachPiPPreview(controller: pip)
                            .frame(width: previewWidth, height: previewWidth / CoachBoardRenderer.aspectRatio)
                            .allowsHitTesting(false)
                            .accessibilityLabel("棋盘指导预览")
                            .accessibilityIdentifier("coach.preview")
                        if !model.broadcastConnectionState.canResumeGuidance {
                            BroadcastPickerView(title: model.broadcastConnectionState == .interrupted ? "重新连接" : "开始", isEnabled: true, onTap: model.prepareToStart)
                                .frame(width: 220, height: 68)
                        }
                    }
                    .frame(width: previewWidth, height: previewWidth / CoachBoardRenderer.aspectRatio)

                    // 固定操作区域，录屏开始/结束只切换按钮，不重建或隐藏上面的显示层。
                    ZStack {
                        if model.broadcastConnectionState.canResumeGuidance {
                            Button(action: model.resumeGuidance) {
                                Text("继续指导")
                                    .font(.system(size: 23, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 220, height: 68)
                                    .background(green)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("coach.resume")
                        }
                    }
                    .frame(height: 68)
                    .padding(.top, 16)

                    Spacer(minLength: 12)
                    Text(model.broadcastConnectionState.canResumeGuidance ? "跟随悬浮窗里的箭头，继续对局" : "开始后确认系统录屏，即可切回棋盘")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $showsHelp) {
            CoachHelpView(model: model, pip: pip)
                .presentationCornerRadius(0)
        }
    }
}

/// 二级帮助独立滚动，首页保持单入口；不提供会改变识别/录屏行为的设置开关。
private struct CoachHelpView: View {
    @ObservedObject var model: CoachViewModel
    @ObservedObject var pip: PiPCoachController
    @Environment(\.dismiss) private var dismiss

    private let green = Color(red: 0.10, green: 0.32, blue: 0.25)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 20) {
                        sectionTitle("开始使用")
                        step("01", title: "点击首页“开始”", detail: "在系统面板中选择“棋研录屏”，再点“开始直播”。iOS 的录屏确认必须由你完成，应用无法跳过。")
                        step("02", title: "切回你的棋盘", detail: "录屏开启后会自动显示悬浮指导。进入对局，保持整张棋盘和棋子清晰可见。")
                        step("03", title: "跟着箭头落子", detail: "我方回合显示绿色指引并播报；对手回合显示蓝色分析，不播报。选子时仍可回看上一条走法。")
                        step("04", title: "恢复或结束指导", detail: "关掉悬浮窗后，可回首页点“继续指导”。若画面中断，首页会恢复录屏入口；点“重新连接”，在系统面板中开启“棋研录屏”。其他应用的录屏不能向棋研提供画面。要结束指导，请在 iOS 录屏控制里停止直播。")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("指定木纹棋盘")
                        Text("仅支持指定木纹棋盘。请使用之前确认过的木纹主题和棋子样式。红黑朝向与当前轮次自动判断，无需校准或手动同步。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("悔棋与恢复")
                        Text("我方或对方悔棋后，保持棋盘稳定，自动恢复已记录的局面和轮次；超出已记录历史时需等待可信上一步标记。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("诊断信息")
                        diagnosticRow("准备", model.recognitionPreparationStatus)
                        diagnosticRow("录屏", model.captureStatus)
                        diagnosticRow("悬浮", pip.isPictureInPictureActive ? "运行中" : "未开启")
                        diagnosticRow("识别", model.recognitionStatus)
                        diagnosticRow("轮次", model.turnStatus)
                        diagnosticRow("收到画面", "\(model.receivedFrameCount) 帧")
                        diagnosticRow("延迟", model.latencyStatus)
                        if let error = pip.errorMessage { diagnosticRow("提示", error) }
                        diagnosticRow("当前建议", model.recommendation)
                        Text(model.recommendationDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.white)
            .navigationTitle("使用帮助")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(green)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("coach.help.done")
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(green)
            .accessibilityAddTraits(.isHeader)
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(green)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func diagnosticRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(detail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
    }
}
