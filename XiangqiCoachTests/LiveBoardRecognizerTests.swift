import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import XiangqiCoach

/// 只覆盖用户指定的两张对局截图；原点和大小独立记录，不由生产布局反推。
@MainActor
final class LiveBoardRecognizerTests: XCTestCase {
    func testUserSpecifiedRedOpeningAtIndependent1280ScreenCoordinates() throws {
        _ = try verify(
            fixture: "user-red-opening-20260915", screenSize: CGSize(width: 1280, height: 2781),
            cropRect: CGRect(x: 12, y: 722, width: 1256, height: 1393),
            expectedBottom: .red, expected: .standard)
    }

    func testUserSpecifiedBlackH2E2AtIndependent1320ScreenCoordinates() throws {
        let move = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        let expected = XiangqiPosition.standard.applying(move)
        XCTAssertEqual(expected.sideToMove, .black)
        let position = try verify(
            fixture: "user-black-h2e2-20260915", screenSize: CGSize(width: 1320, height: 2868),
            cropRect: CGRect(x: 10, y: 740, width: 1300, height: 1444),
            expectedBottom: .black, expected: expected)
        XCTAssertNil(position[Square(row: 7, column: 7)], "原炮位白色光点必须识别为空")
        XCTAssertEqual(position[Square(row: 7, column: 4)], Piece(side: .red, kind: .cannon), "高亮不能改变中炮类型或红色归属")
    }

    private func verify(fixture: String, screenSize: CGSize, cropRect: CGRect,
                        expectedBottom: Side, expected: XiangqiPosition) throws -> XiangqiPosition {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: fixture, withExtension: "png", subdirectory: "Fixtures"))
        let crop = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(crop.cgImage?.width, Int(cropRect.width))
        XCTAssertEqual(crop.cgImage?.height, Int(cropRect.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let screen = UIGraphicsImageRenderer(size: screenSize, format: format).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: screenSize))
            // 原像素大小拼接；不借用 BoardLayout 的交叉点或缩放值。
            crop.draw(at: cropRect.origin)
        }
        let fullImage = try XCTUnwrap(screen.cgImage)
        let scale = 720 / max(screenSize.width, screenSize.height)
        let shrunk = CIImage(cgImage: fullImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        let data = try XCTUnwrap(context.jpegRepresentation(of: shrunk, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let compressed = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(compressed.height, 720)
        let attachment = XCTAttachment(image: UIImage(cgImage: compressed))
        attachment.name = "\(fixture)-独立坐标-720-JPEG0.5"
        attachment.lifetime = .keepAlways
        add(attachment)

        let result = try BoardRecognizer.preset().recognize(compressed, sideToMove: expected.sideToMove)
        XCTAssertEqual(result.boardAtBottom, expectedBottom)
        XCTAssertEqual(result.position, expected)
        XCTAssertEqual(result.position.sideToMove, expected.sideToMove)
        for row in 0..<10 {
            for column in 0..<9 {
                let square = Square(row: row, column: column)
                XCTAssertEqual(result.position[square], expected[square], "\(fixture) 第 \(row) 行第 \(column) 列")
            }
        }
        return result.position
    }
}
