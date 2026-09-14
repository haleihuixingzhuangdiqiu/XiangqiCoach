import ReplayKit
import SwiftUI

struct BroadcastPickerView: UIViewRepresentable {
    static let extensionBundleIdentifier = "com.lgj.xiangqicoach.broadcast"
    static let buttonSize: CGFloat = 54

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // ReplayKit 根据初始尺寸建立内部按钮，必须给真实尺寸才能保留点击区域。
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize))
        picker.preferredExtension = Self.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.tintColor = .systemRed
        for button in picker.subviews.compactMap({ $0 as? UIButton }) {
            button.tintColor = .systemRed
            // 系统原图在部分 iOS 版本固定为黑色；仅替换图像，保留 ReplayKit 的原生点击事件。
            let symbol = UIImage(systemName: "record.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold))
            button.setImage(symbol?.withTintColor(.systemRed, renderingMode: .alwaysOriginal), for: .normal)
        }
        picker.accessibilityLabel = "开启棋研录屏"
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RPSystemBroadcastPickerView, context: Context) -> CGSize? {
        CGSize(width: Self.buttonSize, height: Self.buttonSize)
    }
}
