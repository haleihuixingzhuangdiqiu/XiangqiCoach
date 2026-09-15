import UIKit

/// 所有棋子和走法共用同一坐标变换；黑方在下时同时翻转行、列，避免镜像箭头。
struct CoachBoardGeometry {
    let grid: CGRect
    let boardAtBottom: Side

    var cellSize: CGFloat { min(grid.width / 8, grid.height / 9) }

    func point(for square: Square) -> CGPoint {
        let row = boardAtBottom == .red ? square.row : 9 - square.row
        let column = boardAtBottom == .red ? square.column : 8 - square.column
        return CGPoint(
            x: grid.minX + CGFloat(column) * grid.width / 8,
            y: grid.minY + CGFloat(row) * grid.height / 9
        )
    }

    /// 箭头从起点棋子边缘出发，指向目标交叉点；箭头头部大小不随着法距离拉伸。
    func arrowPoints(for move: XiangqiMove) -> [CGPoint] {
        guard move.from.isOnBoard, move.to.isOnBoard, move.from != move.to else { return [] }
        let origin = point(for: move.from)
        let target = point(for: move.to)
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let distance = hypot(dx, dy)
        guard distance > 0 else { return [] }
        let forward = CGPoint(x: dx / distance, y: dy / distance)
        let normal = CGPoint(x: -forward.y, y: forward.x)
        let startInset = min(cellSize * 0.46, distance * 0.46)
        let length = distance - startInset
        let headLength = min(cellSize * 0.22, length * 0.6)
        let shaftHalfWidth = cellSize * 0.025
        let headHalfWidth = cellSize * 0.105
        func offsetPoint(along: CGFloat, across: CGFloat) -> CGPoint {
            CGPoint(
                x: origin.x + forward.x * along + normal.x * across,
                y: origin.y + forward.y * along + normal.y * across
            )
        }
        return [
            offsetPoint(along: startInset, across: shaftHalfWidth),
            offsetPoint(along: distance - headLength, across: shaftHalfWidth),
            offsetPoint(along: distance - headLength, across: headHalfWidth),
            target,
            offsetPoint(along: distance - headLength, across: -headHalfWidth),
            offsetPoint(along: distance - headLength, across: -shaftHalfWidth),
            offsetPoint(along: startInset, across: -shaftHalfWidth),
        ]
    }
}

/// 延续原棋盘布局，素材恢复来源与裁剪范围见 Resources/ProUI/ASSET_PROVENANCE.json。
/// 网格、棋子与指引共用实际局面的坐标变换；没有已确认棋盘时只呈现等待状态。
enum CoachBoardRenderer {
    static let canvasSize = CGSize(width: 800, height: 600)
    static let aspectRatio: CGFloat = 4.0 / 3.0
    static let grid = CGRect(x: 44, y: 38, width: 464, height: 522)

    private static let boardPanel = CGRect(x: 12, y: 8, width: 528, height: 584)
    private static let paper = UIColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1)
    private static let ink = UIColor(red: 0.19, green: 0.22, blue: 0.20, alpha: 1)
    private static let secondaryInk = UIColor(red: 0.45, green: 0.46, blue: 0.40, alpha: 1)
    private static let boardInk = UIColor(red: 0.43, green: 0.28, blue: 0.13, alpha: 1)
    private static let guide = UIColor(red: 0.16, green: 0.72, blue: 0.58, alpha: 1)
    private static let recallGuide = UIColor(red: 0.65, green: 0.39, blue: 0.10, alpha: 1)
    private static let woodTexture = mirroredWoodTile()
    private static let pieceImages: [Piece: UIImage] = {
        var images: [Piece: UIImage] = [:]
        for side in Side.allCases {
            for kind in PieceKind.allCases {
                if let image = asset(named: "pro_\(side.rawValue)_\(kind.rawValue)") {
                    images[Piece(side: side, kind: kind)] = image
                }
            }
        }
        return images
    }()

    static var hasCompleteProAssets: Bool { woodTexture != nil && pieceImages.count == 14 }

    static func image(for state: CoachOverlayState) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            if let position = state.position {
                drawBoard(position, state: state, in: context.cgContext)
                drawGuidance(state, position: position, in: context.cgContext)
            } else {
                drawWaitingState(state, in: context.cgContext)
            }
        }
    }

    /// 不允许把过期或非法走法画在新局面上；文字与箭头必须采用同一个通过校验的 move。
    static func displayedMove(for state: CoachOverlayState) -> XiangqiMove? {
        guard state.boardIsCurrent, let position = state.position, let move = state.suggestedMove,
              move.from.isOnBoard, move.to.isOnBoard,
              position.legalMoves().contains(move) else { return nil }
        return move
    }

    /// 回看必须绑定原推荐的完整局面和方向；当前有效建议优先，不能把旧箭头套在新棋盘上。
    static func displayedRecall(for state: CoachOverlayState) -> CoachMoveRecall? {
        guard displayedMove(for: state) == nil, let recall = state.previousSuggestion,
              state.position == recall.position, state.boardAtBottom == recall.boardAtBottom,
              recall.move.from.isOnBoard, recall.move.to.isOnBoard,
              recall.position.legalMoves().contains(recall.move) else { return nil }
        return recall
    }

    /// 实时建议与上一条走法采用相同坐标和短着法，但来源标识、箭头和状态各自明确。
    static func guidanceText(for state: CoachOverlayState) -> String {
        if let position = state.position, let move = displayedMove(for: state) {
            return MoveNotation.chinese(move, in: position)
        }
        if let recall = displayedRecall(for: state) {
            return MoveNotation.chinese(recall.move, in: recall.position)
        }
        guard state.boardIsCurrent else { return "等待棋盘更新" }
        return state.suggestedMove == nil ? state.move : "等待最新建议"
    }

    static func boardCaption(for state: CoachOverlayState) -> String {
        if displayedRecall(for: state) != nil { return "上一条走法" }
        guard state.boardIsCurrent else { return "上次确认局面" }
        return displayedMove(for: state) == nil ? "实时棋局" : "推荐走法"
    }

    static func guidanceDetail(for state: CoachOverlayState) -> String {
        if displayedRecall(for: state) != nil { return "等待落子确认，选子后仍可回看这条建议" }
        guard state.boardIsCurrent else { return "保留棋盘供查看，确认最新局面后再显示落子建议" }
        return state.suggestedMove != nil && displayedMove(for: state) == nil
            ? "局面已变化，正在更新建议" : state.detail
    }

    static func instructionLines(for state: CoachOverlayState) -> [String] {
        if displayedRecall(for: state) != nil {
            return ["原起点：圈选棋子", "原落点：箭头位置", "对应上次确认的局面"]
        }
        guard displayedMove(for: state) != nil else { return [] }
        return ["先点圈选棋子", "再点箭头落点", "落子由你操作"]
    }

    private static func asset(named name: String) -> UIImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProUI")
            ?? Bundle.main.url(forResource: name, withExtension: "png")
        return url.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// 相邻纹理镜像接合，避免小块真实木纹重复平铺时产生明显的横向/纵向接缝。
    private static func mirroredWoodTile() -> UIImage? {
        guard let source = asset(named: "pro_wood_texture") else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: source.size.width * 2, height: source.size.height * 2)
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            for row in 0..<2 {
                for column in 0..<2 {
                    renderer.cgContext.saveGState()
                    renderer.cgContext.translateBy(x: column == 0 ? 0 : size.width, y: row == 0 ? 0 : size.height)
                    renderer.cgContext.scaleBy(x: column == 0 ? 1 : -1, y: row == 0 ? 1 : -1)
                    source.draw(in: CGRect(origin: .zero, size: source.size))
                    renderer.cgContext.restoreGState()
                }
            }
        }
    }

    private static func drawBoard(_ position: XiangqiPosition, state: CoachOverlayState, in context: CGContext) {
        drawWoodPanel(in: context)
        drawGrid(in: context)
        let geometry = CoachBoardGeometry(grid: grid, boardAtBottom: state.boardAtBottom)
        for row in 0..<10 {
            for column in 0..<9 {
                let square = Square(row: row, column: column)
                guard let piece = position[square], let image = pieceImages[piece] else { continue }
                let center = geometry.point(for: square)
                let width = geometry.cellSize * 0.91
                // PNG 上部为圆棋子、下部含原始立体阴影；按圆心对齐，保留源图比例与透明边缘。
                image.draw(in: CGRect(x: center.x - width / 2, y: center.y - width / 2,
                                      width: width, height: width * image.size.height / image.size.width))
            }
        }
        if let move = displayedMove(for: state) {
            drawMove(move, geometry: geometry, recalled: false, in: context)
        } else if let recall = displayedRecall(for: state) {
            drawMove(recall.move, geometry: geometry, recalled: true, in: context)
        }
    }

    private static func drawWoodPanel(in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 7,
                          color: UIColor(red: 0.30, green: 0.20, blue: 0.10, alpha: 0.22).cgColor)
        UIColor(red: 0.49, green: 0.32, blue: 0.15, alpha: 1).setFill()
        UIBezierPath(roundedRect: boardPanel, cornerRadius: 15).fill()
        context.restoreGState()

        context.saveGState()
        UIBezierPath(roundedRect: boardPanel.insetBy(dx: 1, dy: 1), cornerRadius: 14).addClip()
        gradient(in: boardPanel, colors: [
            UIColor(red: 0.91, green: 0.78, blue: 0.57, alpha: 1),
            UIColor(red: 0.64, green: 0.45, blue: 0.23, alpha: 1),
            UIColor(red: 0.39, green: 0.25, blue: 0.12, alpha: 1),
        ], context: context)
        context.restoreGState()

        let face = boardPanel.insetBy(dx: 5, dy: 5).offsetBy(dx: 0, dy: -1)
        context.saveGState()
        UIBezierPath(roundedRect: face, cornerRadius: 10).addClip()
        if let woodTexture { UIColor(patternImage: woodTexture).setFill() }
        else { UIColor(red: 0.81, green: 0.66, blue: 0.43, alpha: 1).setFill() }
        context.fill(face)
        gradient(in: face, colors: [UIColor.white.withAlphaComponent(0.17), UIColor.white.withAlphaComponent(0.02),
                                   UIColor(red: 0.36, green: 0.20, blue: 0.07, alpha: 0.12)], context: context)
        context.restoreGState()
        UIColor.white.withAlphaComponent(0.40).setStroke()
        let rim = UIBezierPath(roundedRect: face.insetBy(dx: 0.7, dy: 0.7), cornerRadius: 9)
        rim.lineWidth = 1.1
        rim.stroke()
    }

    private static func drawGrid(in context: CGContext) {
        let step = grid.width / 8
        context.setStrokeColor(boardInk.withAlphaComponent(0.63).cgColor)
        context.setLineWidth(1.1)
        context.stroke(grid.insetBy(dx: -4, dy: -4))
        context.setStrokeColor(boardInk.withAlphaComponent(0.52).cgColor)
        for row in 0..<10 {
            let y = grid.minY + CGFloat(row) * step
            line(from: CGPoint(x: grid.minX, y: y), to: CGPoint(x: grid.maxX, y: y), in: context)
        }
        for column in 0..<9 {
            let x = grid.minX + CGFloat(column) * step
            if column == 0 || column == 8 {
                line(from: CGPoint(x: x, y: grid.minY), to: CGPoint(x: x, y: grid.maxY), in: context)
            } else {
                line(from: CGPoint(x: x, y: grid.minY), to: CGPoint(x: x, y: grid.minY + 4 * step), in: context)
                line(from: CGPoint(x: x, y: grid.minY + 5 * step), to: CGPoint(x: x, y: grid.maxY), in: context)
            }
        }
        for topRow in [0, 7] {
            let y = grid.minY + CGFloat(topRow) * step
            line(from: CGPoint(x: grid.minX + 3 * step, y: y), to: CGPoint(x: grid.minX + 5 * step, y: y + 2 * step), in: context)
            line(from: CGPoint(x: grid.minX + 5 * step, y: y), to: CGPoint(x: grid.minX + 3 * step, y: y + 2 * step), in: context)
        }
        for row in [2, 7] { for column in [1, 7] { crossMarks(row: row, column: column, step: step, in: context) } }
        for row in [3, 6] { for column in [0, 2, 4, 6, 8] { crossMarks(row: row, column: column, step: step, in: context) } }
        let riverY = grid.minY + 4 * step + 11
        text("楚 河", in: CGRect(x: grid.minX + 36, y: riverY, width: 148, height: 38),
             size: 27, weight: .regular, color: boardInk.withAlphaComponent(0.84), alignment: .center, serif: true)
        text("漢 界", in: CGRect(x: grid.maxX - 184, y: riverY, width: 148, height: 38),
             size: 27, weight: .regular, color: boardInk.withAlphaComponent(0.84), alignment: .center, serif: true)
    }

    private static func crossMarks(row: Int, column: Int, step: CGFloat, in context: CGContext) {
        let center = CGPoint(x: grid.minX + CGFloat(column) * step, y: grid.minY + CGFloat(row) * step)
        for dx in [-1.0, 1.0] where (dx < 0 && column > 0) || (dx > 0 && column < 8) {
            for dy in [-1.0, 1.0] {
                let x = center.x + CGFloat(dx) * 4
                let y = center.y + CGFloat(dy) * 4
                context.move(to: CGPoint(x: x, y: y + CGFloat(dy) * 5))
                context.addLine(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + CGFloat(dx) * 5, y: y))
                context.strokePath()
            }
        }
    }

    private static func drawMove(_ move: XiangqiMove, geometry: CoachBoardGeometry, recalled: Bool, in context: CGContext) {
        let origin = geometry.point(for: move.from)
        let target = geometry.point(for: move.to)
        let color = recalled ? recallGuide : guide
        ring(at: origin, radius: geometry.cellSize * 0.47, color: UIColor.white.withAlphaComponent(0.70), width: 4, in: context)
        context.saveGState()
        if recalled { context.setLineDash(phase: 0, lengths: [5, 3]) }
        ring(at: origin, radius: geometry.cellSize * 0.47, color: color, width: 2.4, in: context)
        context.restoreGState()
        let points = geometry.arrowPoints(for: move)
        guard let first = points.first else { return }
        if recalled {
            // 棕色虚线明确表示上一条；保留同一个起点、落点和箭头方向帮助记忆。
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(geometry.cellSize * 0.065)
            context.setLineDash(phase: 0, lengths: [7, 4])
            line(from: CGPoint(x: (points[0].x + points[6].x) / 2, y: (points[0].y + points[6].y) / 2),
                 to: CGPoint(x: (points[1].x + points[5].x) / 2, y: (points[1].y + points[5].y) / 2), in: context)
            context.restoreGState()
            let head = UIBezierPath()
            head.move(to: points[2])
            head.addLine(to: points[3])
            head.addLine(to: points[4])
            head.close()
            color.setFill()
            head.fill()
        } else {
            let arrow = UIBezierPath()
            arrow.move(to: first)
            points.dropFirst().forEach { arrow.addLine(to: $0) }
            arrow.close()
            UIColor.white.withAlphaComponent(0.58).setStroke()
            arrow.lineWidth = 1
            arrow.lineJoinStyle = .round
            arrow.stroke()
            color.withAlphaComponent(0.92).setFill()
            arrow.fill()
        }
        disc(at: target, radius: geometry.cellSize * 0.12, fill: color.withAlphaComponent(0.78), in: context)
        ring(at: target, radius: geometry.cellSize * 0.20, color: color.withAlphaComponent(0.65), width: 1.8, in: context)
    }

    private static func drawGuidance(_ state: CoachOverlayState, position: XiangqiPosition, in context: CGContext) {
        let x: CGFloat = 558
        let width: CGFloat = 220
        let isRecall = displayedRecall(for: state) != nil
        let markerColor = isRecall ? recallGuide : guide
        disc(at: CGPoint(x: x + 4, y: 39), radius: 3.5, fill: isRecall ? recallGuide : state.accent, in: context)
        text(isRecall ? "等待落子确认" : state.title, in: CGRect(x: x + 16, y: 24, width: width - 16, height: 58),
             size: 20, weight: .semibold, color: ink)
        if isRecall {
            recallGuide.withAlphaComponent(0.10).setFill()
            UIBezierPath(roundedRect: CGRect(x: x - 6, y: 90, width: width + 12, height: 38), cornerRadius: 8).fill()
        }
        text(boardCaption(for: state), in: CGRect(x: x, y: 98, width: width, height: 25),
             size: isRecall ? 18 : 16, weight: isRecall ? .semibold : .medium, color: isRecall ? recallGuide : secondaryInk)
        let guidance = guidanceText(for: state)
        text(guidance, in: CGRect(x: x - 1, y: 132, width: width + 2, height: 93),
             size: 36, weight: .semibold, color: ink)
        text(guidanceDetail(for: state), in: CGRect(x: x, y: 238, width: width, height: 92),
             size: 18, weight: .regular, color: secondaryInk)
        context.setStrokeColor(boardInk.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        line(from: CGPoint(x: x, y: 348), to: CGPoint(x: x + width, y: 348), in: context)

        let instructions = instructionLines(for: state)
        if instructions.count == 3 {
            ring(at: CGPoint(x: x + 11, y: 388), radius: 8, color: markerColor, width: 2.2, in: context)
            text(instructions[0], in: CGRect(x: x + 31, y: 372, width: width - 31, height: 34),
                 size: 20, weight: .medium, color: ink)
            disc(at: CGPoint(x: x + 11, y: 442), radius: 7, fill: markerColor, in: context)
            text(instructions[1], in: CGRect(x: x + 31, y: 426, width: width - 31, height: 34),
                 size: 20, weight: .medium, color: ink)
            text(instructions[2], in: CGRect(x: x, y: 480, width: width, height: 27),
                 size: 16, weight: .regular, color: secondaryInk)
        } else {
            text(state.boardIsCurrent ? "\(position.sideToMove.displayName)行棋" : "局面待确认", in: CGRect(x: x, y: 374, width: width, height: 38),
                 size: 24, weight: .semibold, color: ink)
            text(state.boardIsCurrent ? "显示已确认的实际局面" : "更新前暂不提供落子指令", in: CGRect(x: x, y: 430, width: width, height: 56),
                 size: 18, weight: .regular, color: secondaryInk)
        }
        UIColor(red: 0.87, green: 0.90, blue: 0.84, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: x - 2, y: 538, width: width + 4, height: 36), cornerRadius: 9).fill()
        text("\(state.boardAtBottom.displayName)在下 · \(isRecall ? "上次局面" : "自动对齐")", in: CGRect(x: x + 3, y: 545, width: width - 6, height: 25),
             size: 17, weight: .medium, color: ink, alignment: .center)
    }

    private static func drawWaitingState(_ state: CoachOverlayState, in context: CGContext) {
        let panel = CGRect(x: 26, y: 26, width: 748, height: 548)
        UIColor.white.withAlphaComponent(0.50).setFill()
        UIBezierPath(roundedRect: panel, cornerRadius: 24).fill()
        UIColor(red: 0.82, green: 0.73, blue: 0.56, alpha: 0.50).setStroke()
        let border = UIBezierPath(roundedRect: panel, cornerRadius: 24)
        border.lineWidth = 1
        border.stroke()
        disc(at: CGPoint(x: 66, y: 88), radius: 5, fill: state.accent, in: context)
        text(state.title, in: CGRect(x: 86, y: 68, width: 620, height: 47), size: 28, weight: .medium, color: secondaryInk)
        text(state.move, in: CGRect(x: 60, y: 191, width: 680, height: 137), size: 51, weight: .semibold, color: ink)
        text(state.detail, in: CGRect(x: 64, y: 354, width: 672, height: 91), size: 28, weight: .regular, color: secondaryInk)
        context.setStrokeColor(boardInk.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        line(from: CGPoint(x: 64, y: 483), to: CGPoint(x: 736, y: 483), in: context)
        text("识别棋盘后显示走法指引", in: CGRect(x: 64, y: 510, width: 672, height: 35),
             size: 23, weight: .regular, color: secondaryInk)
    }

    private static func gradient(in rect: CGRect, colors: [UIColor], context: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    }

    private static func line(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private static func ring(at center: CGPoint, radius: CGFloat, color: UIColor, width: CGFloat, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func disc(at center: CGPoint, radius: CGFloat, fill: UIColor, in context: CGContext) {
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func text(_ text: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor,
                             alignment: NSTextAlignment = .left, serif: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        paragraph.lineSpacing = size * 0.08
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = serif ? font.fontDescriptor.withDesign(.serif) ?? font.fontDescriptor : font.fontDescriptor
        (text as NSString).draw(in: rect, withAttributes: [
            .font: UIFont(descriptor: descriptor, size: size),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
