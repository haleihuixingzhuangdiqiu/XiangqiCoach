import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CoachViewModel
    @ObservedObject private var pip: PiPCoachController

    init(model: CoachViewModel) {
        self.model = model
        self.pip = model.pipController
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    practiceSettingsCard
                    startCard
                    diagnosticsCard
                }
                .padding(16)
            }
            .background(Color(red: 0.035, green: 0.047, blue: 0.067).ignoresSafeArea())
            .navigationTitle("棋研悬浮教练")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "scope")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("对局棋盘，实时给招")
                        .font(.title3.bold())
                    Text("录屏帧、局面和计算全部留在本机")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.isRecognizerReady ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: 8) {
                statusPill(model.isRecognizerReady ? "识别就绪" : "准备中", color: model.isRecognizerReady ? .green : .orange)
                statusPill(model.isScreenCaptured ? "录屏中" : "未录屏", color: model.isScreenCaptured ? .red : .gray)
                statusPill(model.pipController.isPictureInPictureActive ? "悬浮中" : "未悬浮", color: model.pipController.isPictureInPictureActive ? .blue : .gray)
            }
            Text(model.recognitionPreparationStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var practiceSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("指导设置", systemImage: "slider.horizontal.3")
                .font(.headline)

            HStack {
                Text("当前轮到")
                Spacer()
                Picker("当前轮到", selection: $model.manualSideToMove) {
                    Text("红方").tag(Side.red)
                    Text("黑方").tag(Side.black)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
                Button("同步") { model.resynchronizeTurn() }
                    .buttonStyle(.bordered)
            }

            Text("仅支持指定的木纹对局棋盘，红黑方向自动识别。中途进入时可确认轮次后点“同步”。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("语音播报建议着法", isOn: $model.voiceEnabled)
        }
        .cardStyle()
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("开始指导", systemImage: "play.circle.fill")
                .font(.headline)

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.red.opacity(0.18))
                    BroadcastPickerView()
                        .frame(width: BroadcastPickerView.buttonSize, height: BroadcastPickerView.buttonSize)
                }
                .frame(width: 66, height: 66)

                VStack(alignment: .leading, spacing: 3) {
                    Text("① 点红色录屏按钮")
                        .font(.headline)
                    Text(model.autoStartPictureInPicture ? "确认开始后会自动打开悬浮指导" : "选择“棋研录屏”并点开始直播")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            CoachPiPPreview(controller: model.pipController)
                .aspectRatio(CoachBoardRenderer.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

            Toggle("录屏开始后自动悬浮", isOn: $model.autoStartPictureInPicture)

            Button {
                if model.pipController.isPictureInPictureActive {
                    model.stopPictureInPicture()
                } else {
                    model.startPictureInPicture()
                }
            } label: {
                Label(
                    model.pipController.isPictureInPictureActive ? "关闭悬浮指导" : "手动开启悬浮指导",
                    systemImage: model.pipController.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.pipController.isPictureInPictureActive ? .gray : .green)

            if let error = model.pipController.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text("确认“棋研录屏”后会自动开启悬浮窗，再切到指定的对局棋盘并露出全部棋子。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("实时状态", systemImage: "waveform.path.ecg")
                .font(.headline)
            detailRow("录屏", model.captureStatus)
            detailRow("识别", model.recognitionStatus)
            detailRow("收到画面", "\(model.receivedFrameCount) 帧")
            detailRow("延迟", model.latencyStatus)

            Divider()
            Text(model.recommendation)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.green)
            Text(model.recommendationDetail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)

            if let preview = model.livePreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .cardStyle()
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote)
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
