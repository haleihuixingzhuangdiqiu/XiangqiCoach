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

    /// 新提交的独立实图，按记录的原像素坐标复原；不是训练模板，也不修改图中的标记。
    func testActualLastMoveMarkersAtOriginalAndBroadcastResolutionIgnoreInputTurn() throws {
        let screen = try markerScreen()
        for image in [try XCTUnwrap(screen.cgImage), try compressed(screen)] {
            for turn in Side.allCases {
                let result = try BoardRecognizer.preset().recognize(image, sideToMove: turn)
                XCTAssertTrue(result.position.hasSameBoard(as: afterH2E2))
                XCTAssertEqual(result.position.sideToMove, turn, "图像证据本身不覆盖轮次")
                XCTAssertEqual(result.boardAtBottom, .black)
                XCTAssertEqual(result.lastMove, BoardMoveEvidence(move: h2e2, movedSide: .red))
            }
        }
    }

    func testActualUnmarkedRedOpeningHasNoLastMoveEvidence() throws {
        let screen = try fixtureScreen("user-red-opening-20260915", size: CGSize(width: 1280, height: 2781),
                                       crop: CGRect(x: 12, y: 722, width: 1256, height: 1393))
        for image in [try XCTUnwrap(screen.cgImage), try compressed(screen)] {
            let result = try BoardRecognizer.preset().recognize(image, sideToMove: .red)
            XCTAssertEqual(result.position, .standard)
            XCTAssertNil(result.lastMove)
        }
    }

    /// 合成正例：只搬运实图标记/棋子原像素到红底相应格，验证方向变换；不是第二张真实已走红底照片。
    func testSyntheticRedBottomPairMapsToSameCanonicalMove() throws {
        let red = try fixtureScreen("user-red-opening-20260915", size: CGSize(width: 1280, height: 2781),
                                    crop: CGRect(x: 12, y: 722, width: 1256, height: 1393))
        let marked = try markerScreen()
        let withCannon = try paste(marked, row: 2, column: 4, into: red, row: 7, column: 4)
        let moved = try paste(marked, row: 2, column: 1, into: withCannon, row: 7, column: 7)
        for image in [try XCTUnwrap(moved.cgImage), try compressed(moved)] {
            let result = try BoardRecognizer.preset().recognize(image, sideToMove: .black)
            XCTAssertTrue(result.position.hasSameBoard(as: afterH2E2))
            XCTAssertEqual(result.boardAtBottom, .red)
            XCTAssertEqual(result.lastMove, BoardMoveEvidence(move: h2e2, movedSide: .red))
        }
    }

    /// 合成正例：将落点棋面换为真实黑炮字色，白圈保持实图像素；侧别必须来自落点棋子，不能固定为红方。
    func testSyntheticBlackCannonMarkerReadsActualPieceColor() throws {
        let red = try fixtureScreen("user-red-opening-20260915", size: CGSize(width: 1280, height: 2781),
                                    crop: CGRect(x: 12, y: 722, width: 1256, height: 1393))
        let marked = try markerScreen()
        let withHalo = try paste(marked, row: 2, column: 4, into: red, row: 2, column: 4)
        let withBlackFace = try paste(red, row: 2, column: 7, into: withHalo, row: 2, column: 4, span: 0.84, elliptical: true)
        let moved = try paste(marked, row: 2, column: 1, into: withBlackFace, row: 2, column: 7)
        let move = XiangqiMove(from: Square(row: 2, column: 7), to: Square(row: 2, column: 4))
        var previous = XiangqiPosition.standard
        previous.sideToMove = .black
        let expected = previous.applying(move)
        for image in [try XCTUnwrap(moved.cgImage), try compressed(moved)] {
            let result = try BoardRecognizer.preset().recognize(image, sideToMove: .red)
            XCTAssertEqual(result.position, expected)
            XCTAssertEqual(result.boardAtBottom, .red)
            XCTAssertEqual(result.lastMove, BoardMoveEvidence(move: move, movedSide: .black))
        }
    }

    /// 以下均为显式合成负例。无真实选子录屏样本，故只证明残缺/重复几何标记不会提供轮次证据。
    func testSyntheticSelectionOnlyAndOriginOnlyHaveNoEvidence() throws {
        let marked = try markerScreen()
        let selectionOnly = try paste(marked, row: 2, column: 2, into: marked, row: 2, column: 1, span: 0.8)
        let originOnly = try paste(marked, row: 2, column: 7, into: marked, row: 2, column: 4)
        try assertNoLastMove(selectionOnly, label: "仅有落点/选中圈")
        try assertNoLastMove(originOnly, label: "仅有起点")
    }

    func testSyntheticIsolatedWhiteDotWithoutSmallRingIsRejected() throws {
        let marked = try markerScreen()
        let erased = try paste(marked, row: 2, column: 2, into: marked, row: 2, column: 1, span: 0.8)
        let dotOnly = try paste(marked, row: 2, column: 1, into: erased, row: 2, column: 1, span: 0.16)
        try assertNoLastMove(dotOnly, label: "白点缺少完整小环")
    }

    func testSyntheticMultipleOriginsOrDestinationsAreAmbiguous() throws {
        let marked = try markerScreen()
        let origins = try paste(marked, row: 2, column: 1, into: marked, row: 2, column: 2, span: 0.8)
        let destinations = try paste(marked, row: 2, column: 4, into: marked, row: 2, column: 7)
        try assertNoLastMove(origins, label: "两个起点")
        try assertNoLastMove(destinations, label: "两个落点/同时选中")
    }

    func testSyntheticOffBoardWhiteMarksAndNonBoardDoNotProvideEvidence() throws {
        let red = try fixtureScreen("user-red-opening-20260915", size: CGSize(width: 1280, height: 2781),
                                    crop: CGRect(x: 12, y: 722, width: 1256, height: 1393))
        let outside = makeRenderer(red.size).image { context in
            red.draw(at: .zero)
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 200, y: 300, width: 20, height: 20))
            context.cgContext.setStrokeColor(UIColor.white.cgColor)
            context.cgContext.setLineWidth(4)
            context.cgContext.strokeEllipse(in: CGRect(x: 500, y: 280, width: 130, height: 130))
        }
        let result = try BoardRecognizer.preset().recognize(compressed(outside), sideToMove: .red)
        XCTAssertEqual(result.position, .standard)
        XCTAssertNil(result.lastMove)
        let blank = makeRenderer(red.size).image { context in
            UIColor(white: 0.4, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: red.size))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 230, y: 1090, width: 20, height: 20))
        }
        let recognizer = try BoardRecognizer.preset()
        XCTAssertThrowsError(try recognizer.recognize(compressed(blank), sideToMove: .red))
    }

    /// 连续帧合成回归：实图开局上的单选中圈只搬运真实高亮炮像素，不代表真实选子录屏。
    func testSyntheticSelectionRecoversAndTracksNextMoveFromActualPixels() throws {
        let clean = try redOpeningScreen()
        let selected = try paste(markerScreen(), row: 2, column: 4, into: clean, row: 7, column: 7)
        try verifyTransientRecovery(clean: clean, transient: selected, expectsRejection: false,
                                    attachmentName: "合成序列-选子后恢复")
    }

    /// 把当前 renderer 的实际画面合成到棋盘上；圆角仅模拟系统 PiP 遮罩，不是一次实机录屏。
    func testSyntheticPiPOcclusionIsRejectedThenRecoversAndTracksNextMove() throws {
        let clean = try redOpeningScreen()
        let overlay = CoachBoardRenderer.image(for: CoachOverlayState(
            title: "轮到你 · 红方", move: "炮二平五", detail: "已识别 · 建议走法",
            position: .standard, suggestedMove: h2e2, boardAtBottom: .red))
        let obscured = makeRenderer(clean.size).image { context in
            clean.draw(at: .zero)
            // 棋盘上方首排的将帅位落在浮窗实心内容内，而不是透明圆角或窗外阴影中。
            let window = CGRect(x: 64, y: 690, width: 768, height: 576)
            context.cgContext.saveGState()
            UIBezierPath(roundedRect: window, cornerRadius: 96).addClip()
            overlay.draw(in: window)
            context.cgContext.restoreGState()
        }
        try verifyTransientRecovery(clean: clean, transient: obscured, expectsRejection: true,
                                    attachmentName: "合成序列-PiP实心区域遮挡后恢复")
    }

    /// 每一帧都先经过真实 720/JPEG 0.5 识别，再把识别输出交给 Tracker；不注入理想识别结果。
    /// 末帧的 h2e2 来自真实走子截图的原棋子/标记像素，仅转换到同一红底方向，不冒充另一张实机截图。
    private func verifyTransientRecovery(clean: UIImage, transient: UIImage, expectsRejection: Bool,
                                         attachmentName: String) throws {
        let recognizer = try BoardRecognizer.preset()
        var tracker = BoardTracker()
        for index in 0..<2 {
            let recognized = try recognizer.recognize(compressed(clean), sideToMove: .black)
            XCTAssertTrue(recognized.position.hasSameBoard(as: .standard))
            XCTAssertEqual(recognized.boardAtBottom, .red)
            let observation = tracker.observe(recognized.position, lastMove: recognized.lastMove)
            XCTAssertEqual(observation, index == 0 ? .confirming : .accepted(.standard, .newGame))
        }
        let historyBefore = try XCTUnwrap(tracker.analysisHistory)
        let transientSample = try compressed(transient)
        if expectsRejection {
            XCTAssertThrowsError(try recognizer.recognize(transientSample, sideToMove: .black)) { _ in
                // 只有真实识别拒绝了这张遮挡图，才走生产的丢帧分支。
                tracker.loseBoard()
            }
        } else {
            let recognized = try recognizer.recognize(transientSample, sideToMove: .black)
            XCTAssertTrue(recognized.position.hasSameBoard(as: .standard))
            XCTAssertEqual(recognized.boardAtBottom, .red)
            XCTAssertNil(recognized.lastMove, "单选中圈不能被解释成已经落子")
            XCTAssertEqual(tracker.observe(recognized.position, lastMove: recognized.lastMove), .unchanged(.standard))
        }
        XCTAssertEqual(tracker.position, .standard)
        XCTAssertEqual(tracker.analysisHistory, historyBefore)

        for _ in 0..<2 {
            let recognized = try recognizer.recognize(compressed(clean), sideToMove: .black)
            XCTAssertEqual(recognized.boardAtBottom, .red)
            XCTAssertEqual(tracker.observe(recognized.position, lastMove: recognized.lastMove), .unchanged(.standard))
            XCTAssertEqual(tracker.position?.sideToMove, .red, "恢复同一棋盘不能采信错误输入轮次")
            XCTAssertEqual(tracker.analysisHistory, historyBefore)
        }

        let marked = try markerScreen()
        let withCannon = try paste(marked, row: 2, column: 4, into: clean, row: 7, column: 4)
        let moved = try paste(marked, row: 2, column: 1, into: withCannon, row: 7, column: 7)
        for index in 0..<2 {
            let recognized = try recognizer.recognize(compressed(moved), sideToMove: .red)
            XCTAssertTrue(recognized.position.hasSameBoard(as: afterH2E2))
            XCTAssertEqual(recognized.boardAtBottom, .red)
            XCTAssertEqual(recognized.lastMove, BoardMoveEvidence(move: h2e2, movedSide: .red))
            let observation = tracker.observe(recognized.position, lastMove: recognized.lastMove)
            XCTAssertEqual(observation, index == 0 ? .confirming : .accepted(afterH2E2, .legalMoves(1)))
            XCTAssertEqual(tracker.position, index == 0 ? .standard : afterH2E2)
        }
        XCTAssertEqual(tracker.position?.sideToMove, .black)
        XCTAssertEqual(tracker.analysisHistory, AnalysisHistory(root: .standard, moves: [h2e2]))
        for (label, image) in [("干扰帧", transientSample), ("恢复后已走h2e2", try compressed(moved))] {
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "\(attachmentName)-\(label)-720-JPEG0.5"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func redOpeningScreen() throws -> UIImage {
        try fixtureScreen("user-red-opening-20260915", size: CGSize(width: 1280, height: 2781),
                          crop: CGRect(x: 12, y: 722, width: 1256, height: 1393))
    }

    private var h2e2: XiangqiMove { XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4)) }
    private var afterH2E2: XiangqiPosition { XiangqiPosition.standard.applying(h2e2) }

    private func markerScreen() throws -> UIImage {
        try fixtureScreen("user-last-move-h2e2-20260915", size: CGSize(width: 1320, height: 2868),
                          crop: CGRect(x: 10, y: 740, width: 1300, height: 1444))
    }

    private func fixtureScreen(_ name: String, size: CGSize, crop: CGRect) throws -> UIImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(image.cgImage?.width, Int(crop.width))
        XCTAssertEqual(image.cgImage?.height, Int(crop.height))
        return makeRenderer(size).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(at: crop.origin)
        }
    }

    private func makeRenderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private func compressed(_ image: UIImage) throws -> CGImage {
        let full = try XCTUnwrap(image.cgImage)
        let scale = 720 / Double(full.height)
        let reduced = CIImage(cgImage: full).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let data = try XCTUnwrap(CIContext(options: [.cacheIntermediates: false]).jpegRepresentation(
            of: reduced, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func assertNoLastMove(_ image: UIImage, label: String) throws {
        for sample in [try XCTUnwrap(image.cgImage), try compressed(image)] {
            let result = try BoardRecognizer.preset().recognize(sample, sideToMove: .black)
            XCTAssertTrue(result.position.hasSameBoard(as: afterH2E2), label)
            XCTAssertNil(result.lastMove, label)
        }
    }

    /// 合成样本的格点硬编码自记录坐标，不调用生产 BoardLayout；像素搬运不会被冒充为新实图。
    private func patchRect(row: Int, column: Int, size: CGSize, span: CGFloat) -> CGRect {
        let x = (96 + CGFloat(column) * 136) / 1280 * size.width
        let y = (802 + CGFloat(row) * 1220 / 9) / 2781 * size.height
        let width = 136 / 1280 * size.width * span
        let height = 1220 / 9 / 2781 * size.height * span
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    private func paste(_ source: UIImage, row sourceRow: Int, column sourceColumn: Int,
                       into target: UIImage, row targetRow: Int, column targetColumn: Int,
                       span: CGFloat = 1.10, elliptical: Bool = false) throws -> UIImage {
        let sourceRect = patchRect(row: sourceRow, column: sourceColumn, size: source.size, span: span).integral
        let destination = patchRect(row: targetRow, column: targetColumn, size: target.size, span: span).integral
        let patch = UIImage(cgImage: try XCTUnwrap(source.cgImage?.cropping(to: sourceRect)))
        return makeRenderer(target.size).image { context in
            target.draw(at: .zero)
            if elliptical { context.cgContext.addEllipse(in: destination); context.cgContext.clip() }
            patch.draw(in: destination)
        }
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
