import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct RecognitionResult {
    let position: XiangqiPosition
    let boardAtBottom: Side
    let layout: BoardLayout
    /// 视觉上完整的上一步标记；轮次仍由 BoardTracker 的稳定帧和棋规判定。
    var lastMove: BoardMoveEvidence? = nil
    /// 32×32 RGB 去均值后的平均通道绝对差；用于观测字形匹配程度，不受局部整体明暗平移影响。
    let meanDistance: Float
    let maximumDistance: Float
    var qualityText: String { "棋盘已确认" }
}

/// 固定棋盘主题的像素识别器。初始化后只读；由专用串行队列处理录屏帧。
/// 先根据实际字色和字形分类，再用双将位置判朝向；不接受外部指定的执棋方。
final class BoardRecognizer: @unchecked Sendable {
    private struct Feature {
        let pixels: [Float]
        let inkChroma: Float?
        let sharpness: Float
    }
    private struct Template {
        let piece: Piece?
        let feature: Feature
    }
    private let templates: [Template]
    private let lastMoveRecognizer: LastMoveRecognizer?
    private let fixedLayout: BoardLayout?
    private let maximumDistanceByPiece: [Piece?: Float]
    private let minimumPieceSharpness: Float
    private final class PresetCache: @unchecked Sendable {
        let lock = NSLock()
        var recognizer: BoardRecognizer?
    }
    private static let cache = PresetCache()
    private let maximumBlackInkChroma: Float
    private let minimumRedInkChroma: Float

    static func preset() throws -> BoardRecognizer {
        // 方向只能由识别后的棋盘确定。两种朝向共用只读模板，重复进入时不再解码。
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let existing = cache.recognizer { return existing }
        let recognizer = try BoardRecognizer(bundle: .main)
        cache.recognizer = recognizer
        return recognizer
    }

    convenience init(bundle: Bundle = .main) throws {
        var images: [(CGImage, BoardLayout, XiangqiPosition)] = []
        for side in Side.allCases {
            guard let url = bundle.url(forResource: "board-template-\(side.rawValue)", withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw BoardRecognitionError.templateUnavailable
            }
            var annotated = XiangqiPosition.standard
            if side == .black {
                // 第二张实图是红方 h2e2 后轮到黑方，不是标准开局。
                annotated[Square(row: 7, column: 4)] = annotated[Square(row: 7, column: 7)]
                annotated[Square(row: 7, column: 7)] = nil
                annotated.sideToMove = .black
            }
            images.append((image, .template(boardAtBottom: side), annotated))
        }
        let references = images.map { image, layout, position in
            LastMoveRecognizer.Reference(image: image, layout: layout, position: position,
                lastMove: layout.boardAtBottom == .black ? BoardMoveEvidence(
                    move: XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4)), movedSide: .red) : nil,
                fullScreenHeight: 2781)
        }
        try self.init(annotatedImages: images, lastMoveReferences: references)
    }

    /// 测试和显式标准局面模板入口；内置的已走棋模板使用带真实局面标注的初始化器。
    convenience init(templateImage: CGImage, templateLayout: BoardLayout, screenLayout: BoardLayout) throws {
        try self.init(annotatedImages: [(templateImage, templateLayout, .standard)], fixedLayout: screenLayout)
    }

    init(annotatedImages: [(CGImage, BoardLayout, XiangqiPosition)], fixedLayout: BoardLayout? = nil,
         lastMoveReferences: [LastMoveRecognizer.Reference] = []) throws {
        var collected: [Template] = []
        var variations = annotatedImages
        var blurredMinimums: [Float] = []
        let context = CIContext(options: [.cacheIntermediates: false])
        for (image, layout, position) in annotatedImages {
            // 训练实际录屏压缩后的字色/笔画，避免仅用原始高清样本划定过窄颜色范围。
            let scale = 720.0 / 2781.0
            let reduced = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // 实测在 720 高度的 0.6px 模糊开始出现黑炮误红，作为清晰度负样本。
            let blurred = reduced.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6]).cropped(to: reduced.extent)
            if let data = context.jpegRepresentation(of: blurred, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let sample = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                var weakest = Float.greatestFiniteMagnitude
                for row in 0..<10 { for column in 0..<9 {
                    let square = layout.boardAtBottom == .red ? Square(row: row, column: column)
                        : Square(row: 9 - row, column: 8 - column)
                    if position[square] != nil {
                        weakest = min(weakest, try Self.feature(sample, rect: layout.normalizedRect, row: row, column: column).sharpness)
                    }
                } }
                blurredMinimums.append(weakest)
            }
            for quality in [0.35, 0.7] {
                guard let data = context.jpegRepresentation(of: reduced, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]),
                    let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let compressed = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw BoardRecognitionError.featureGenerationFailed
                }
                variations.append((compressed, layout, position))
            }
        }
        for (image, layout, position) in variations {
            for row in 0..<10 {
                for column in 0..<9 {
                    let square = layout.boardAtBottom == .red
                        ? Square(row: row, column: column)
                        : Square(row: 9 - row, column: 8 - column)
                    let feature = try Self.feature(image, rect: layout.normalizedRect, row: row, column: column)
                    collected.append(Template(piece: position[square], feature: feature))
                }
            }
        }
        guard !collected.isEmpty else { throw BoardRecognitionError.templateUnavailable }
        templates = collected
        lastMoveRecognizer = lastMoveReferences.isEmpty ? nil : try LastMoveRecognizer(references: lastMoveReferences)
        self.fixedLayout = fixedLayout
        // 同类正常模板的最大两两差作为类别边界，不用全盘平均数掩盖局部遮挡。
        var classBounds: [Piece?: Float] = [:]
        var scratch = [Float](repeating: 0, count: 3072)
        for first in collected.indices {
            for second in 0..<first where collected[first].piece == collected[second].piece {
                let distance = Self.distance(collected[first].feature.pixels, collected[second].feature.pixels, scratch: &scratch)
                classBounds[collected[first].piece] = max(classBounds[collected[first].piece] ?? 0, distance)
            }
        }
        maximumDistanceByPiece = classBounds
        let weakestPositive = collected.filter { $0.piece != nil }.map { $0.feature.sharpness }.min() ?? 0
        let strongestBlur = blurredMinimums.max() ?? weakestPositive
        // 已测正负区间有间隔时取中点；区间重叠时只依赖模板匹配与九宫，不猜清晰度阈值。
        minimumPieceSharpness = strongestBlur < weakestPositive ? (strongestBlur + weakestPositive) / 2 : 0
        maximumBlackInkChroma = collected.compactMap { $0.piece?.side == .black ? $0.feature.inkChroma : nil }.max() ?? -.infinity
        minimumRedInkChroma = collected.compactMap { $0.piece?.side == .red ? $0.feature.inkChroma : nil }.min() ?? .infinity
    }

    func recognize(_ image: CGImage, sideToMove: Side) throws -> RecognitionResult {
        let layouts = fixedLayout.map { [$0] } ?? BoardLayout.candidates(for: CGSize(width: image.width, height: image.height))
        guard !layouts.isEmpty else { throw BoardRecognitionError.boardCropFailed }
        var best: RecognitionResult?
        for layout in layouts {
            guard let result = try? recognize(image, layout: layout, sideToMove: sideToMove) else { continue }
            if best == nil || result.meanDistance < best!.meanDistance { best = result }
        }
        guard let best else { throw BoardRecognitionError.unrecognizedBoard }
        return best
    }

    private func recognize(_ image: CGImage, layout: BoardLayout, sideToMove: Side) throws -> RecognitionResult {
        var screen = [Piece?](repeating: nil, count: 90)
        var sum: Float = 0
        var maximum: Float = 0
        var scratch = [Float](repeating: 0, count: 3072)
        for row in 0..<10 {
            for column in 0..<9 {
                let feature = try Self.feature(image, rect: layout.normalizedRect, row: row, column: column)
                let side = inkSide(feature.inkChroma)
                var distance = Float.greatestFiniteMagnitude
                var piece: Piece?
                for template in templates {
                    if let side, let templateSide = template.piece?.side, side != templateSide { continue }
                    let candidate = Self.distance(feature.pixels, template.feature.pixels, scratch: &scratch)
                    if candidate < distance { distance = candidate; piece = template.piece }
                }
                // 质量边界从正常压缩与模糊样本实测生成，细节见识别质量文档。
                guard distance <= (maximumDistanceByPiece[piece] ?? 0),
                      piece == nil || feature.sharpness >= minimumPieceSharpness else {
                    throw BoardRecognitionError.unrecognizedBoard
                }
                screen[row * 9 + column] = piece
                sum += distance
                maximum = max(maximum, distance)
            }
        }
        guard let bottom = Self.boardAtBottom(screen) else {
            throw BoardRecognitionError.unrecognizedBoard
        }
        let board = bottom == .red ? screen : Array(screen.reversed())
        let position = XiangqiPosition(board: board, sideToMove: sideToMove)
        guard Self.isPlausible(position) else { throw BoardRecognitionError.unrecognizedBoard }
        let oriented = layout.oriented(bottom)
        return RecognitionResult(position: position, boardAtBottom: bottom, layout: oriented,
                                 lastMove: lastMoveRecognizer?.recognize(image, position: position, layout: oriented),
                                 meanDistance: sum / 90, maximumDistance: maximum)
    }

    /// 只在已知颜色分布之外作确定判断。两簇之间留白，避免把棕色棋线/色彩配置差异硬切成红字。
    private func inkSide(_ value: Float?) -> Side? {
        guard maximumBlackInkChroma < minimumRedInkChroma, let value else { return nil }
        if value <= maximumBlackInkChroma { return .black }
        if value >= minimumRedInkChroma { return .red }
        return nil
    }

    private static func boardAtBottom(_ pieces: [Piece?]) -> Side? {
        let generals = pieces.indices.filter { pieces[$0]?.kind == .general }
        guard generals.count == 2,
              let red = generals.first(where: { pieces[$0]?.side == .red }),
              let black = generals.first(where: { pieces[$0]?.side == .black }),
              (3...5).contains(red % 9), (3...5).contains(black % 9) else { return nil }
        if (7...9).contains(red / 9), (0...2).contains(black / 9) { return .red }
        if (0...2).contains(red / 9), (7...9).contains(black / 9) { return .black }
        return nil
    }

    private static func isPlausible(_ position: XiangqiPosition) -> Bool {
        for side in Side.allCases {
            var counts: [PieceKind: Int] = [:]
            for row in 0..<10 {
                for column in 0..<9 {
                    if let piece = position[Square(row: row, column: column)], piece.side == side {
                        counts[piece.kind, default: 0] += 1
                    }
                }
            }
            guard counts[.general] == 1 else { return false }
            for kind in PieceKind.allCases where kind != .general {
                if counts[kind, default: 0] > (kind == .pawn ? 5 : 2) { return false }
            }
        }
        return true
    }

    private static func feature(_ image: CGImage, rect: CGRect, row: Int, column: Int) throws -> Feature {
        let x = rect.minX * CGFloat(image.width)
        let y = rect.minY * CGFloat(image.height)
        let stepX = rect.width * CGFloat(image.width) / 8
        let stepY = rect.height * CGFloat(image.height) / 9
        let size = min(stepX, stepY) * 0.84
        let cell = CGRect(x: x + CGFloat(column) * stepX - size / 2,
                          y: y + CGFloat(row) * stepY - size / 2, width: size, height: size).integral
        guard cell.minX >= 0, cell.minY >= 0, cell.maxX <= CGFloat(image.width), cell.maxY <= CGFloat(image.height),
              cell.width >= 16, cell.height >= 16, let crop = image.cropping(to: cell) else {
            throw BoardRecognitionError.boardCropFailed
        }
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let ok = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard ok else { throw BoardRecognitionError.featureGenerationFailed }
        var pixels = [Float](repeating: 0, count: 3072)
        bytes.withUnsafeBufferPointer { input in
            pixels.withUnsafeMutableBufferPointer { output in
                for channel in 0..<3 {
                    vDSP_vfltu8(input.baseAddress! + channel, 4, output.baseAddress! + channel * 1024, 1, 1024)
                }
            }
        }
        var luminance = [Float](repeating: 0, count: 1024)
        for i in 0..<1024 { luminance[i] = (pixels[i] + pixels[i + 1024] + pixels[i + 2048]) / 3 }
        var differences: Float = 0
        for y in 0..<32 {
            for x in 0..<31 { differences += abs(luminance[y * 32 + x] - luminance[y * 32 + x + 1]) }
        }
        for y in 0..<31 {
            for x in 0..<32 { differences += abs(luminance[y * 32 + x] - luminance[(y + 1) * 32 + x]) }
        }
        // 浮窗投影会压暗棋面；先在原始像素上保留颜色与清晰度，再去掉每通道整体亮度用于字形匹配。
        // 只抵消局部明暗平移，不补锐、不放宽质量门限；模糊和颜色判断仍使用原始数据。
        let chroma = inkChroma(pixels, luminance: luminance)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for channel in 0..<3 {
                let start = buffer.baseAddress! + channel * 1024
                var mean: Float = 0
                vDSP_meanv(start, 1, &mean, 1024)
                var offset = -mean
                vDSP_vsadd(start, 1, &offset, start, 1, 1024)
            }
        }
        return Feature(pixels: pixels, inkChroma: chroma, sharpness: differences / Float(2 * 32 * 31))
    }

    /// Otsu 只读取棋面内圈，避开边缘金圈和外部白色走棋光晕；阈值由每格实际亮度分布产生。
    private static func inkChroma(_ pixels: [Float], luminance: [Float]) -> Float? {
        let mask = (0..<1024).filter { index in
            let x = Float(index % 32) - 15.5, y = Float(index / 32) - 15.5
            return x * x + y * y <= 11 * 11
        }
        var histogram = [Int](repeating: 0, count: 256)
        for i in mask { histogram[min(255, max(0, Int(luminance[i])))] += 1 }
        let total = mask.count
        let totalIntensity = histogram.indices.reduce(0.0) { $0 + Double($1 * histogram[$1]) }
        var darkCount = 0, darkSum: Double = 0, largest: Double = -1
        var cutoff = 0
        for threshold in 0..<255 {
            darkCount += histogram[threshold]
            darkSum += Double(threshold * histogram[threshold])
            let lightCount = total - darkCount
            guard darkCount > 0, lightCount > 0 else { continue }
            let delta = darkSum / Double(darkCount) - (totalIntensity - darkSum) / Double(lightCount)
            let variance = Double(darkCount * lightCount) * delta * delta
            if variance > largest { largest = variance; cutoff = threshold }
        }
        var red: Float = 0, green: Float = 0, blue: Float = 0
        for i in mask where Int(luminance[i]) <= cutoff {
            red += pixels[i]; green += pixels[i + 1024]; blue += pixels[i + 2048]
        }
        let totalColor = red + green + blue
        return totalColor > 0 ? (red - green) / totalColor : nil
    }

    private static func distance(_ lhs: [Float], _ rhs: [Float], scratch: inout [Float]) -> Float {
        var result: Float = 0
        vDSP_vsub(lhs, 1, rhs, 1, &scratch, 1, vDSP_Length(lhs.count))
        vDSP_svemg(scratch, 1, &result, vDSP_Length(lhs.count))
        return result / Float(lhs.count)
    }
}
