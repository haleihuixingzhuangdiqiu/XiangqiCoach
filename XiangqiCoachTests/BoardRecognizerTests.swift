import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import XiangqiCoach

@MainActor
final class BoardRecognizerTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func testRedOpeningFromActualBoardCrop() throws {
        let result = try BoardRecognizer.preset().recognize(
            broadcast(frame(board(.red))), sideToMove: .red)
        XCTAssertEqual(result.position, .standard)
        XCTAssertEqual(result.boardAtBottom, .red)
        XCTAssertEqual(result.layout.id, "specified-wood-board")
    }

    func testBlackBottomIsActualH2E2AndWhiteOriginHighlightIsEmpty() throws {
        let result = try BoardRecognizer.preset().recognize(
            broadcast(frame(board(.black))), sideToMove: .black)
        XCTAssertEqual(result.position, afterRedCannon)
        XCTAssertEqual(result.boardAtBottom, .black)
        XCTAssertNil(result.position[Square(row: 7, column: 7)])
        XCTAssertEqual(result.position[Square(row: 7, column: 4)], Piece(side: .red, kind: .cannon))
    }

    /// 真实棋盘像素经 UIKit 拼回屏幕，再走录屏同款 CoreImage 720/900/1080 高度与 JPEG 编解码。
    func testSpecifiedBoardBothResolutionsAndOrientationsCompressionMatrix() throws {
        let recognizer = try BoardRecognizer.preset()
        for side in Side.allCases {
            for modern in [true, false] {
                let screen = try frame(board(side), modern: modern)
                for height in [720.0, 900.0, 1080.0] {
                    for quality in [0.35, 0.5, 0.7] {
                        let image = try broadcast(screen, height: height, quality: quality)
                        let result = try recognizer.recognize(image, sideToMove: side == .red ? .red : .black)
                        XCTAssertEqual(result.position, side == .red ? .standard : afterRedCannon,
                                       "\(side) modern=\(modern) height=\(height) JPEG=\(quality)")
                        XCTAssertEqual(result.boardAtBottom, side)
                        XCTAssertEqual(result.layout.id, "specified-wood-board")
                    }
                }
            }
        }
    }

    func testInputTurnNeverChangesRecognizedPieceColorsOrOrientation() throws {
        for side in Side.allCases {
            let screen = try broadcast(frame(board(side)))
            for inputTurn in Side.allCases {
                let result = try BoardRecognizer.preset().recognize(screen, sideToMove: inputTurn)
                var expected = side == .red ? XiangqiPosition.standard : afterRedCannon
                expected.sideToMove = inputTurn
                XCTAssertEqual(result.position, expected)
                XCTAssertEqual(result.boardAtBottom, side)
            }
        }
    }

    func testRedAndBlackPawnsAcrossRiverUseInkColor() throws {
        let original = try board(.red)
        let top = Square(row: 3, column: 0), bottom = Square(row: 6, column: 0)
        let swapped = try replaceCells(original, replacements: [(top, original, bottom), (bottom, original, top)])
        var expected = XiangqiPosition.standard
        let red = expected[bottom]
        expected[bottom] = expected[top]
        expected[top] = red
        let result = try BoardRecognizer.preset().recognize(broadcast(frame(swapped)), sideToMove: .red)
        XCTAssertEqual(result.position, expected)
    }

    func testBlackBottomStandardCanBeRestoredWithoutRelabelingMovedFixture() throws {
        let moved = try board(.black), red = try board(.red)
        let restored = try replaceCells(moved, replacements: [
            (Square(row: 2, column: 1), moved, Square(row: 2, column: 7)),
            (Square(row: 2, column: 4), red, Square(row: 2, column: 4))
        ])
        let result = try BoardRecognizer.preset().recognize(broadcast(frame(restored)), sideToMove: .red)
        XCTAssertEqual(result.position, .standard)
        XCTAssertEqual(result.boardAtBottom, .black)
    }

    func testGeneralOutsidePalaceIsRejectedDespiteValidPieceCounts() throws {
        let original = try board(.red)
        let moved = try replaceCells(original, replacements: [
            (Square(row: 9, column: 4), original, Square(row: 8, column: 4)),
            (Square(row: 5, column: 4), original, Square(row: 9, column: 4))
        ])
        let recognizer = try BoardRecognizer.preset()
        XCTAssertThrowsError(try recognizer.recognize(broadcast(frame(moved)), sideToMove: .red))
    }

    func testOccludedGeneralIsRejected() throws {
        let original = try board(.red)
        let obscured = renderer(original.size).image { context in
            original.draw(at: .zero)
            UIColor(white: 0.2, alpha: 1).setFill()
            context.fill(cellRect(Square(row: 9, column: 4), size: original.size))
        }
        let recognizer = try BoardRecognizer.preset()
        XCTAssertThrowsError(try recognizer.recognize(broadcast(frame(obscured)), sideToMove: .red))
    }

    func testFloatingWindowShadowPreservesBothPieceColorsWithoutCoveringChessmen() throws {
        let recognizer = try BoardRecognizer.preset()
        for side in Side.allCases {
            let screen = try frame(board(side))
            let shadowed = renderer(screen.size).image { context in
                screen.draw(at: .zero)
                // 固定实图坐标：浮窗本体在首排棋子上方，只有向下投影落到右侧棋面。
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 12), blur: 36,
                                            color: UIColor.black.withAlphaComponent(0.55).cgColor)
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 500, y: 180, width: 750, height: 562), cornerRadius: 40).fill()
            }
            let result = try recognizer.recognize(broadcast(shadowed), sideToMove: side)
            XCTAssertEqual(result.position, side == .red ? .standard : afterRedCannon)
            XCTAssertEqual(result.boardAtBottom, side)
        }
    }

    func testBlurRejectedBeforeItCanChangeCannonColor() throws {
        let recognizer = try BoardRecognizer.preset()
        for side in Side.allCases {
            let screen = try frame(board(side))
            for blur in [0.6, 1.0, 1.5] {
                XCTAssertThrowsError(try recognizer.recognize(broadcast(screen, blur: blur), sideToMove: .red))
            }
        }
    }

    func testBlankAndUniformOverlayAreRejected() throws {
        let recognizer = try BoardRecognizer.preset()
        let blank = renderer(CGSize(width: 1280, height: 2781)).image { context in
            UIColor(red: 0.85, green: 0.65, blue: 0.4, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 2781))
        }
        XCTAssertThrowsError(try recognizer.recognize(broadcast(blank), sideToMove: .red))
        let screen = try frame(board(.red))
        let obscured = renderer(screen.size).image { context in
            screen.draw(at: .zero)
            UIColor(white: 0, alpha: 0.4).setFill()
            context.fill(CGRect(origin: .zero, size: screen.size))
        }
        XCTAssertThrowsError(try recognizer.recognize(broadcast(obscured), sideToMove: .red))
    }

    func testBoardOutsideSupportedGeometryIsRejected() throws {
        let screen = try frame(board(.red), shiftY: 160)
        let recognizer = try BoardRecognizer.preset()
        XCTAssertThrowsError(try recognizer.recognize(broadcast(screen), sideToMove: .red))
    }

    func testRepeatedCompressedFramesAndResolutionSwitchKeepCanonicalBoard() throws {
        let recognizer = try BoardRecognizer.preset()
        for modern in [true, true, false, false, true] {
            let compressed = try broadcast(frame(board(.red), modern: modern))
            XCTAssertEqual(try recognizer.recognize(compressed, sideToMove: .red).position, .standard)
        }
    }

    func testCompressedRecognitionPerformance() throws {
        let recognizer = try BoardRecognizer.preset()
        let compressed = try broadcast(frame(board(.black)))
        XCTAssertEqual(try recognizer.recognize(compressed, sideToMove: .black).position, afterRedCannon)
        measure { _ = try? recognizer.recognize(compressed, sideToMove: .black) }
    }

    private var afterRedCannon: XiangqiPosition {
        XiangqiPosition.standard.applying(XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4)))
    }

    private func board(_ side: Side) throws -> UIImage {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "board-template-\(side.rawValue)", withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path))
    }

    private func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// 两个分辨率共用指定棋盘布局；独立实图坐标验收另由 LiveBoardRecognizerTests 覆盖。
    private func frame(_ board: UIImage, modern: Bool = true, shiftY: CGFloat = 0) throws -> UIImage {
        let size = modern ? CGSize(width: 1280, height: 2781) : CGSize(width: 1320, height: 2868)
        let target = BoardLayout.screen(boardAtBottom: .red).gridRect(in: size)
        let source = BoardLayout.template(boardAtBottom: .red).gridRect(in: board.size)
        let scaleX = target.width / source.width, scaleY = target.height / source.height
        let rect = CGRect(x: target.minX - source.minX * scaleX, y: target.minY - source.minY * scaleY + shiftY,
                          width: board.size.width * scaleX, height: board.size.height * scaleY)
        return renderer(size).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            board.draw(in: rect)
        }
    }

    private func cellRect(_ square: Square, size: CGSize) -> CGRect {
        let rect = BoardLayout.template(boardAtBottom: .red).gridRect(in: size)
        let stepX = rect.width / 8, stepY = rect.height / 9
        let width = min(stepX, stepY) * 0.98
        return CGRect(x: rect.minX + CGFloat(square.column) * stepX - width / 2,
                      y: rect.minY + CGFloat(square.row) * stepY - width / 2, width: width, height: width)
    }

    private func replaceCells(_ image: UIImage, replacements: [(Square, UIImage, Square)]) throws -> UIImage {
        let patches = try replacements.map { target, source, square -> (CGRect, UIImage) in
            let crop = try XCTUnwrap(source.cgImage?.cropping(to: cellRect(square, size: source.size).integral))
            return (cellRect(target, size: image.size).integral, UIImage(cgImage: crop))
        }
        return renderer(image.size).image { _ in
            image.draw(at: .zero)
            for (rect, patch) in patches { patch.draw(in: rect) }
        }
    }

    private func broadcast(_ image: UIImage, height: Double = 720, quality: Double = 0.5, blur: Double = 0) throws -> CGImage {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = height / Double(cgImage.height)
        let shrunk = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let prepared = blur == 0 ? shrunk : shrunk.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: shrunk.extent)
        let data = try XCTUnwrap(context.jpegRepresentation(of: prepared, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
