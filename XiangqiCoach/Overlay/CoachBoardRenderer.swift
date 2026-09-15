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
        let headLength = min(cellSize * 0.26, length * 0.6)
        let shaftHalfWidth = cellSize * 0.040
        let headHalfWidth = cellSize * 0.13
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
    /// 为系统 PiP 圆角保留棋子、阴影和圈选的安全距离；不是把画布四角当成可用区域。
    static let grid = CGRect(x: 88, y: 62, width: 416, height: 468)

    private static let boardPanel = CGRect(x: 0, y: 0, width: 540, height: 600)
    private static let paper = UIColor(red: 0.985, green: 0.983, blue: 0.970, alpha: 1)
    private static let ink = UIColor(red: 0.19, green: 0.22, blue: 0.20, alpha: 1)
    private static let secondaryInk = UIColor(red: 0.39, green: 0.42, blue: 0.38, alpha: 1)
    private static let boardInk = UIColor(red: 0.43, green: 0.28, blue: 0.13, alpha: 1)
    private static let guide = UIColor(red: 0.04, green: 0.51, blue: 0.36, alpha: 1)
    private static let opponentGuide = UIColor(red: 0.16, green: 0.48, blue: 0.83, alpha: 1)
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
            if state.showsStartScreen {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: canvasSize))
                return
            }
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            if let position = state.position {
                drawBoard(position, state: state, in: context.cgContext)
                drawGuidance(state, in: context.cgContext)
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

    static func isOpponentTurn(for state: CoachOverlayState) -> Bool {
        guard let position = state.position else { return false }
        return position.sideToMove != state.boardAtBottom
    }

    static func boardCaption(for state: CoachOverlayState) -> String {
        if displayedRecall(for: state) != nil { return isOpponentTurn(for: state) ? "对手上一条走法" : "上一条走法" }
        guard state.boardIsCurrent else { return "上次确认局面" }
        guard displayedMove(for: state) != nil else { return "实时棋局" }
        return isOpponentTurn(for: state) ? "对手走法" : "推荐走法"
    }

    static func guidanceDetail(for state: CoachOverlayState) -> String {
        if displayedRecall(for: state) != nil {
            return isOpponentTurn(for: state) ? "保留对手上一条预测，等待实际走子确认" : "等待落子确认，选子后仍可回看这条建议"
        }
        guard state.boardIsCurrent else { return "保留棋盘供查看，确认最新局面后再显示落子建议" }
        return state.suggestedMove != nil && displayedMove(for: state) == nil
            ? "局面已变化，正在更新建议" : state.detail
    }

    static func instructionLines(for state: CoachOverlayState) -> [String] {
        if displayedRecall(for: state) != nil {
            return ["原来起点", "原来落点", isOpponentTurn(for: state) ? "对手上一条预测" : "选子时仍可回看"]
        }
        guard displayedMove(for: state) != nil else { return [] }
        if isOpponentTurn(for: state) { return ["可能起点", "可能落点", "蓝色箭头仅作预测"] }
        return ["先点棋子", "再点落点", "跟随绿色箭头"]
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
            drawMove(move, geometry: geometry, recalled: false, opponent: isOpponentTurn(for: state), in: context)
        } else if let recall = displayedRecall(for: state) {
            drawMove(recall.move, geometry: geometry, recalled: true, opponent: isOpponentTurn(for: state), in: context)
        }
    }

    /// 木纹铺到画布的左、上、下边界，由系统 PiP 圆角统一裁切。
    /// 不在这三边再画内缩的直角木框，避免圆角内出现白色月牙和第二层方框。
    private static func drawWoodPanel(in context: CGContext) {
        context.saveGState()
        context.clip(to: boardPanel)
        if let woodTexture { UIColor(patternImage: woodTexture).setFill() }
        else { UIColor(red: 0.81, green: 0.66, blue: 0.43, alpha: 1).setFill() }
        context.fill(boardPanel)
        gradient(in: boardPanel, colors: [UIColor.white.withAlphaComponent(0.17), UIColor.white.withAlphaComponent(0.02),
                                          UIColor(red: 0.36, green: 0.20, blue: 0.07, alpha: 0.12)], context: context)
        context.restoreGState()
        // 只保留与右侧说明区相接的一条直线，棋盘网格仍按真实交叉点绘制。
        context.setStrokeColor(boardInk.withAlphaComponent(0.25).cgColor)
        context.setLineWidth(1)
        line(from: CGPoint(x: boardPanel.maxX - 0.5, y: 0),
             to: CGPoint(x: boardPanel.maxX - 0.5, y: canvasSize.height), in: context)
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

    private static func drawMove(_ move: XiangqiMove, geometry: CoachBoardGeometry, recalled: Bool, opponent: Bool, in context: CGContext) {
        let origin = geometry.point(for: move.from)
        let target = geometry.point(for: move.to)
        let color = recalled ? recallGuide : (opponent ? opponentGuide : guide)
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
            arrow.lineWidth = 1.6
            arrow.lineJoinStyle = .round
            arrow.stroke()
            color.withAlphaComponent(0.92).setFill()
            arrow.fill()
        }
        disc(at: target, radius: geometry.cellSize * 0.055, fill: color.withAlphaComponent(0.45), in: context)
        ring(at: target, radius: geometry.cellSize * 0.20, color: color.withAlphaComponent(0.65), width: 1.8, in: context)
    }

    /// 小浮窗只保留走法、两步图示与局面来源；搜索深度、评分等仍在二级诊断页查看。
    private static func drawGuidance(_ state: CoachOverlayState, in context: CGContext) {
        let x: CGFloat = 558
        let width: CGFloat = 220
        let isRecall = displayedRecall(for: state) != nil
        let hasMove = displayedMove(for: state) != nil || isRecall
        let isOpponent = isOpponentTurn(for: state)
        let markerColor = isRecall ? recallGuide : (isOpponent ? opponentGuide : guide)
        let statusColor = hasMove ? markerColor : state.accent

        // 窄分隔与相同内边距固定内容区域，思考和回看不改变棋盘的尺寸或位置。
        context.setFillColor(UIColor.white.withAlphaComponent(0.58).cgColor)
        context.fill(CGRect(x: 546, y: 8, width: 242, height: 584))
        context.setFillColor(statusColor.cgColor)
        context.fill(CGRect(x: x, y: 28, width: 34, height: 4))
        let heading = isRecall ? (isOpponent ? "对手上条走法" : "上一条走法")
            : (hasMove ? (isOpponent ? "对手预测" : "我方走法") : (state.boardIsCurrent ? state.title : boardCaption(for: state)))
        text(heading, in: CGRect(x: x, y: 50, width: width, height: 58),
             size: 23, weight: .semibold, color: hasMove ? markerColor : secondaryInk)

        let guidance = guidanceText(for: state)
        text(guidance, in: CGRect(x: x - 1, y: 126, width: width + 2, height: 118),
             size: hasMove ? 46 : 32, weight: .bold, color: ink)
        context.setStrokeColor(ink.withAlphaComponent(0.13).cgColor)
        context.setLineWidth(1)
        line(from: CGPoint(x: x, y: 266), to: CGPoint(x: x + width, y: 266), in: context)

        let instructions = instructionLines(for: state)
        if instructions.count == 3 {
            for index in 0..<2 {
                let y: CGFloat = 303 + CGFloat(index) * 80
                markerColor.withAlphaComponent(0.09).setFill()
                context.fill(CGRect(x: x, y: y, width: 42, height: 42))
                let center = CGPoint(x: x + 21, y: y + 21)
                if index == 0 {
                    context.saveGState()
                    if isRecall { context.setLineDash(phase: 0, lengths: [4, 2]) }
                    ring(at: center, radius: 11, color: markerColor, width: 2.8, in: context)
                    context.restoreGState()
                } else {
                    ring(at: center, radius: 11, color: markerColor.withAlphaComponent(0.55), width: 2, in: context)
                    disc(at: center, radius: 5, fill: markerColor, in: context)
                }
                text(instructions[index], in: CGRect(x: x + 57, y: y + 4, width: width - 57, height: 36),
                     size: 27, weight: .semibold, color: ink)
            }
            text(instructions[2], in: CGRect(x: x, y: 464, width: width, height: 57),
                 size: 21, weight: .medium, color: secondaryInk)
        } else {
            // 等待或错误时保留真实状态说明；不把旧棋盘写成可操作的实时指令。
            text(guidanceDetail(for: state), in: CGRect(x: x, y: 301, width: width, height: 187),
                 size: 23, weight: .regular, color: secondaryInk)
        }

        context.setStrokeColor(ink.withAlphaComponent(0.13).cgColor)
        line(from: CGPoint(x: x, y: 514), to: CGPoint(x: x + 186, y: 514), in: context)
        text("\(state.boardAtBottom.displayName)在下", in: CGRect(x: x, y: 529, width: 106, height: 30),
             size: 21, weight: .medium, color: secondaryInk)
        let source = isRecall ? "回看" : (state.boardIsCurrent ? "实时" : "旧局面")
        let sourceColor = isRecall ? recallGuide : (state.boardIsCurrent ? markerColor : secondaryInk)
        sourceColor.withAlphaComponent(0.09).setFill()
        context.fill(CGRect(x: x + 106, y: 524, width: 80, height: 36))
        text(source, in: CGRect(x: x + 109, y: 530, width: 74, height: 27),
             size: 20, weight: .semibold, color: sourceColor, alignment: .center)
    }

    private static func drawWaitingState(_ state: CoachOverlayState, in context: CGContext) {
        let panel = CGRect(x: 26, y: 26, width: 748, height: 548)
        UIColor.white.withAlphaComponent(0.58).setFill()
        context.fill(panel)
        context.setFillColor(state.accent.cgColor)
        context.fill(CGRect(x: 60, y: 66, width: 42, height: 5))
        text(state.title, in: CGRect(x: 60, y: 97, width: 680, height: 52),
             size: 27, weight: .medium, color: secondaryInk)
        text(state.move, in: CGRect(x: 60, y: 198, width: 680, height: 137),
             size: 49, weight: .bold, color: ink)
        text(state.detail, in: CGRect(x: 60, y: 369, width: 680, height: 136),
             size: 29, weight: .regular, color: secondaryInk)
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
