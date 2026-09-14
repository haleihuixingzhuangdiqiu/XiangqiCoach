import CoreGraphics
import Foundation

/// 归一化边界表示四个角部交叉点；坐标原点在截图左上角。颜色方向独立于屏幕布局。
struct BoardLayout: Sendable, Equatable {
    let normalizedRect: CGRect
    let boardAtBottom: Side
    var id: String = "custom"

    /// 唯一支持的对局棋盘；两张指定实图虽为不同分辨率，交叉点布局使用同一归一化坐标。
    static func screen(boardAtBottom: Side) -> BoardLayout {
        BoardLayout(normalizedRect: CGRect(x: 96.0 / 1280, y: 802.0 / 2781,
                                           width: 1088.0 / 1280, height: 1220.0 / 2781),
                    boardAtBottom: boardAtBottom, id: "specified-wood-board")
    }

    /// 两张新实图仅保留木质棋盘，去除头像、昵称和状态栏；黑底资源包含已走的 h2e2。
    static func template(boardAtBottom: Side) -> BoardLayout {
        BoardLayout(normalizedRect: CGRect(x: 84.0 / 1256, y: 80.0 / 1393,
                                           width: 1088.0 / 1256, height: 1220.0 / 1393),
                    boardAtBottom: boardAtBottom, id: "board-crop")
    }

    static func candidates(for size: CGSize) -> [BoardLayout] {
        let aspect = size.width / size.height
        if (0.85...0.95).contains(aspect) { return [.template(boardAtBottom: .red)] }
        guard (0.43...0.49).contains(aspect) else { return [] }
        return [.screen(boardAtBottom: .red)]
    }

    func gridRect(in size: CGSize) -> CGRect {
        CGRect(x: normalizedRect.minX * size.width, y: normalizedRect.minY * size.height,
               width: normalizedRect.width * size.width, height: normalizedRect.height * size.height)
    }

    func oriented(_ side: Side) -> BoardLayout {
        BoardLayout(normalizedRect: normalizedRect, boardAtBottom: side, id: id)
    }
}

enum BoardRecognitionError: LocalizedError {
    case templateUnavailable
    case boardCropFailed
    case featureGenerationFailed
    case unrecognizedBoard

    var errorDescription: String? {
        switch self {
        case .templateUnavailable: return "内置棋盘模板未能加载，请重新打开应用"
        case .boardCropFailed: return "请竖屏显示完整的指定棋盘"
        case .featureGenerationFailed: return "棋子特征提取失败，请等待下一帧"
        case .unrecognizedBoard: return "尚未确认指定棋盘，请露出全部棋子并等走子动画结束"
        }
    }
}
