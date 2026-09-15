import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// 只识别指定主题的成对上一步标记，不决定轮次。调用前必须已确认全盘及真实朝向；
/// 输出仍须经 BoardTracker 连续帧和棋规验证。单独选子的大圈、孤立白点或多组标记均不构成证据。
final class LastMoveRecognizer {
    struct Reference {
        let image: CGImage
        let layout: BoardLayout
        let position: XiangqiPosition
        /// 标注训练图片的真实上一步；nil 表示此图片没有上一步标记。
        let lastMove: BoardMoveEvidence?
        let fullScreenHeight: CGFloat
    }

    private struct Template {
        let hasRing: Bool
        let feature: [Float]
    }
    private let templates: [Template]
    private let maximumRingDistance: Float
    // 24 条射线 × 4 个半径只读棋面以外的环带，不含字形/字色，也不记住训练标记所在格。
    private static let ringOffsets: [CGPoint] = {
        var offsets: [CGPoint] = []
        let radii: [Double] = [0.44, 0.47, 0.50, 0.53]
        for angle in 0..<24 {
            let radians = Double(angle) * Double.pi / 12
            for radius in radii {
                offsets.append(CGPoint(x: cos(radians) * radius, y: sin(radians) * radius))
            }
        }
        return offsets
    }()
    private static let directions = (0..<24).map { angle in
        CGPoint(x: cos(Double(angle) * .pi / 12), y: sin(Double(angle) * .pi / 12))
    }

    init(references: [Reference]) throws {
        var collected: [Template] = []
        let context = CIContext(options: [.cacheIntermediates: false])
        for reference in references {
            var images = [reference.image]
            // 真实 CoreImage/JPEG 色度抽样会削弱白圈，训练原图和录屏变体，不能以高清白色阈值处理录屏。
            for (height, quality) in [(720.0, 0.35), (720, 0.5), (720, 0.7), (900, 0.5), (1080, 0.5)] {
                let scale = height / reference.fullScreenHeight
                let reduced = CIImage(cgImage: reference.image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let data = context.jpegRepresentation(of: reduced, colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]),
                    let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw BoardRecognitionError.featureGenerationFailed
                }
                images.append(image)
            }
            for image in images {
                guard let pixels = Pixels(image) else { throw BoardRecognitionError.featureGenerationFailed }
                for row in 0..<10 { for column in 0..<9 {
                    let square = Self.canonical(row: row, column: column, bottom: reference.layout.boardAtBottom)
                    guard reference.position[square] != nil else { continue }
                    let cell = Cell(row: row, column: column, layout: reference.layout, image: image)
                    collected.append(Template(hasRing: reference.lastMove?.move.to == square,
                                              feature: pixels.ringFeature(cell)))
                } }
            }
        }
        let positives = collected.filter(\.hasRing)
        guard !positives.isEmpty, collected.contains(where: { !$0.hasRing }) else {
            throw BoardRecognitionError.templateUnavailable
        }
        var maximum: Float = 0
        var scratch = [Float](repeating: 0, count: Self.ringOffsets.count * 3)
        // 允许的绝对距离来自同一真实白圈各录屏变体间的最大差，拒绝离所有样本都很远的白色遮挡。
        for first in positives.indices {
            for second in 0..<first {
                maximum = max(maximum, Self.distance(positives[first].feature, positives[second].feature, scratch: &scratch))
            }
        }
        templates = collected
        maximumRingDistance = maximum
    }

    func recognize(_ image: CGImage, position: XiangqiPosition, layout: BoardLayout) -> BoardMoveEvidence? {
        guard let pixels = Pixels(image) else { return nil }
        var origins: [Square] = []
        // 先找小圆环+中心白点。绝大多数未走棋/无标记帧到这里即可返回，避免每帧分类所有外圈。
        for row in 0..<10 { for column in 0..<9 {
            let square = Self.canonical(row: row, column: column, bottom: layout.boardAtBottom)
            guard position[square] == nil else { continue }
            if pixels.hasOrigin(Cell(row: row, column: column, layout: layout, image: image)) { origins.append(square) }
        } }
        guard origins.count == 1 else { return nil }
        var destinations: [Square] = []
        var scratch = [Float](repeating: 0, count: Self.ringOffsets.count * 3)
        for row in 0..<10 { for column in 0..<9 {
            let square = Self.canonical(row: row, column: column, bottom: layout.boardAtBottom)
            guard position[square] != nil else { continue }
            let feature = pixels.ringFeature(Cell(row: row, column: column, layout: layout, image: image))
            var ring = Float.greatestFiniteMagnitude, plain = Float.greatestFiniteMagnitude
            for template in templates {
                let distance = Self.distance(feature, template.feature, scratch: &scratch)
                if template.hasRing { ring = min(ring, distance) } else { plain = min(plain, distance) }
            }
            if ring < plain, ring <= maximumRingDistance { destinations.append(square) }
        } }
        guard destinations.count == 1, let destination = destinations.first, let piece = position[destination] else { return nil }
        return BoardMoveEvidence(move: XiangqiMove(from: origins[0], to: destination), movedSide: piece.side)
    }

    private static func canonical(row: Int, column: Int, bottom: Side) -> Square {
        bottom == .red ? Square(row: row, column: column) : Square(row: 9 - row, column: 8 - column)
    }

    private static func distance(_ lhs: [Float], _ rhs: [Float], scratch: inout [Float]) -> Float {
        vDSP_vsub(lhs, 1, rhs, 1, &scratch, 1, vDSP_Length(lhs.count))
        var sum: Float = 0
        vDSP_svemg(scratch, 1, &sum, vDSP_Length(lhs.count))
        return sum / Float(lhs.count)
    }

    private struct Cell {
        let center: CGPoint
        let step: CGSize
        init(row: Int, column: Int, layout: BoardLayout, image: CGImage) {
            let grid = layout.gridRect(in: CGSize(width: image.width, height: image.height))
            step = CGSize(width: grid.width / 8, height: grid.height / 9)
            center = CGPoint(x: grid.minX + CGFloat(column) * step.width,
                             y: grid.minY + CGFloat(row) * step.height)
        }
        func point(_ offset: CGPoint) -> CGPoint {
            CGPoint(x: center.x + offset.x * step.width, y: center.y + offset.y * step.height)
        }
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var output = [UInt8](repeating: 0, count: width * height * 4)
            let success = output.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard success else { return nil }
            bytes = output
        }
        func color(_ point: CGPoint) -> (Float, Float, Float) {
            let x = min(width - 1, max(0, Int(point.x.rounded())))
            let y = min(height - 1, max(0, Int(point.y.rounded())))
            let index = (y * width + x) * 4
            return (Float(bytes[index]) / 255, Float(bytes[index + 1]) / 255, Float(bytes[index + 2]) / 255)
        }
        func neutral(_ point: CGPoint) -> Float {
            let (r, g, b) = color(point)
            let highest = max(r, max(g, b)), lowest = min(r, min(g, b))
            return highest > 0 ? lowest / highest : 0
        }
        func ringFeature(_ cell: Cell) -> [Float] {
            var result: [Float] = []
            result.reserveCapacity(LastMoveRecognizer.ringOffsets.count * 3)
            for offset in LastMoveRecognizer.ringOffsets {
                let (r, g, b) = color(cell.point(offset))
                result.append(r - b)
                result.append(g - b)
                result.append(b)
            }
            return result
        }
        func hasOrigin(_ cell: Cell) -> Bool {
            let (r, g, b) = color(cell.center)
            // 实图+720/JPEG .5：中心中性色比最小 .91，空格最大 .73；中心最暗通道最小 .91。
            // 中点 .82/.79 留出压缩余量，同时挡住暗黑字、木纹和棋线。不是从棋子位置推断起点。
            guard neutral(cell.center) >= 0.82, min(r, min(g, b)) >= 0.79 else { return false }
            var contrast: Float = 0
            var raisedDirections = 0
            for direction in LastMoveRecognizer.directions {
                func peak(_ radii: ClosedRange<Int>) -> Float {
                    radii.reduce(0) { peak, radius in
                        max(peak, neutral(cell.point(CGPoint(x: direction.x * CGFloat(radius) / 100,
                                                           y: direction.y * CGFloat(radius) / 100))))
                    }
                }
                let delta = peak(17...24) - peak(29...33)
                contrast += delta
                if delta > 0.02 { raisedDirections += 1 }
            }
            // 指定实图小圈的平均中性色提升在原图 .30、录屏 .09；无标记空格接近 0。
            // 要求至少 3/4 周长同时出现环形提升，孤立中心白点或只有一截亮边不能通过。
            return contrast / 24 >= 0.045 && raisedDirections >= 18
        }
    }
}
