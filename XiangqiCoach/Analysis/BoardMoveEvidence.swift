import Foundation

/// 图像中同时确认的上一步起点与落点；坐标已转换为红方视角的标准棋盘坐标。
/// movedSide 必须来自落点上实际识别的棋子颜色，不能来自屏幕朝向或默认轮次。
struct BoardMoveEvidence: Equatable, Sendable {
    let move: XiangqiMove
    let movedSide: Side
}
