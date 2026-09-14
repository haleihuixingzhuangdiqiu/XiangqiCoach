import CoreImage
import ImageIO
import UIKit
import XCTest
@testable import XiangqiCoach

/// 只用 Bundle 中的真实棋盘像素，不注入识别结果、推荐走法或虚构轮次。
@MainActor
final class BoardPipelineTests: XCTestCase {
    func testRedOpeningThroughRecognitionHistoryEngineAndGraphicalGuidance() async throws {
        try await verifyPipeline(boardAtBottom: .red, movesFromStandard: [], attachmentName: "完整链路-红底开局-实际引擎建议")
    }

    func testBlackBottomH2E2ThroughRecognitionHistoryEngineAndGraphicalGuidance() async throws {
        let cannon = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        try await verifyPipeline(boardAtBottom: .black, movesFromStandard: [cannon], attachmentName: "完整链路-黑底h2e2-实际引擎建议")
    }

    private func verifyPipeline(boardAtBottom: Side, movesFromStandard: [XiangqiMove], attachmentName: String) async throws {
        let expected = movesFromStandard.reduce(XiangqiPosition.standard) { $0.applying($1) }
        let recognizer = try BoardRecognizer.preset()
        var tracker = BoardTracker()
        var recognizedBottom: Side?
        for frameIndex in 0..<2 {
            let compressed = try broadcastFrame(boardAtBottom: boardAtBottom)
            // 故意给相反轮次，要求 Tracker 根据标准起点及真实走子独立证明谁走。
            let recognition = try recognizer.recognize(compressed, sideToMove: expected.sideToMove.opponent)
            XCTAssertTrue(recognition.position.hasSameBoard(as: expected))
            XCTAssertEqual(recognition.boardAtBottom, boardAtBottom)
            recognizedBottom = recognition.boardAtBottom
            let observation = tracker.observe(recognition.position)
            if frameIndex == 0 {
                XCTAssertEqual(observation, .confirming)
                XCTAssertNil(tracker.position)
            } else {
                let reason: BoardTracker.Acceptance = movesFromStandard.isEmpty ? .newGame : .legalMoves(movesFromStandard.count)
                XCTAssertEqual(observation, .accepted(expected, reason))
            }
        }
        let position = try XCTUnwrap(tracker.position)
        let history = try XCTUnwrap(tracker.analysisHistory)
        XCTAssertEqual(position, expected)
        XCTAssertEqual(position.sideToMove, boardAtBottom)
        XCTAssertEqual(history.root, .standard)
        XCTAssertEqual(history.moves, movesFromStandard)
        XCTAssertEqual(history.moves.reduce(history.root) { $0.applying($1) }, position)
        if boardAtBottom == .black {
            XCTAssertNil(position[Square(row: 7, column: 7)], "原炮位白光点不能成为棋子")
            XCTAssertEqual(position[Square(row: 7, column: 4)], Piece(side: .red, kind: .cannon))
            XCTAssertEqual(history.moves.map { $0.iccs() }, ["h2e2"])
        }

        // 与生产相同，在独立串行工作中加载 NNUE 并执行真实搜索，主线程只生成图形。
        let outcome = await Task.detached(priority: .userInitiated) {
            let engine = XiangqiEngine()
            let result = engine.search(position: position, timeLimit: 0.2, history: history)
            return (result, engine.lastError)
        }.value
        XCTAssertNil(outcome.1)
        let result = try XCTUnwrap(outcome.0, outcome.1 ?? "真实引擎未返回走法")
        XCTAssertTrue(position.legalMoves().contains(result.move))
        XCTAssertEqual(position[result.move.from]?.side, position.sideToMove)
        XCTAssertGreaterThan(result.depth, 0)
        XCTAssertGreaterThan(result.nodesVisited, 0)
        XCTAssertEqual(result.principalVariation.first, result.move)
        var replay = position
        for move in result.principalVariation {
            XCTAssertTrue(replay.legalMoves().contains(move))
            replay = replay.applying(move)
        }

        var state = CoachOverlayState(
            title: "轮到你 · \(position.sideToMove.displayName)",
            move: MoveNotation.chinese(result.move, in: position),
            detail: "已识别 · 建议走法", accent: .systemGreen,
            position: position, suggestedMove: result.move,
            boardAtBottom: try XCTUnwrap(recognizedBottom), boardIsCurrent: true
        )
        XCTAssertEqual(CoachBoardRenderer.displayedMove(for: state), result.move)
        XCTAssertEqual(CoachBoardRenderer.guidanceText(for: state), state.move)
        XCTAssertFalse(CoachBoardRenderer.instructionLines(for: state).isEmpty)
        let geometry = CoachBoardGeometry(grid: CoachBoardRenderer.grid, boardAtBottom: state.boardAtBottom)
        let arrow = geometry.arrowPoints(for: result.move)
        XCTAssertEqual(arrow.count, 7)
        XCTAssertEqual(arrow.dropFirst(3).first, geometry.point(for: result.move.to))
        let guidance = CoachBoardRenderer.image(for: state)
        XCTAssertEqual(guidance.size, CoachBoardRenderer.canvasSize)
        let attachment = XCTAttachment(image: guidance)
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)

        tracker.loseBoard()
        XCTAssertEqual(tracker.position, position, "短暂丢帧必须保留最后确认局面")
        XCTAssertEqual(tracker.analysisHistory, history, "丢帧不能丢失重复局面所需走子历史")
        state.position = tracker.position
        state.boardIsCurrent = false
        // 故意保留原建议，验证渲染器主动拒绝过期箭头，不能只靠调用方清空它。
        XCTAssertEqual(state.suggestedMove, result.move)
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
        XCTAssertTrue(CoachBoardRenderer.instructionLines(for: state).isEmpty)
        XCTAssertEqual(CoachBoardRenderer.guidanceText(for: state), "等待棋盘更新")
        XCTAssertEqual(CoachBoardRenderer.boardCaption(for: state), "上次确认局面")
        let staleImage = CoachBoardRenderer.image(for: state)
        var noArrow = state
        noArrow.boardIsCurrent = true
        noArrow.suggestedMove = nil
        let noArrowImage = CoachBoardRenderer.image(for: noArrow)
        XCTAssertEqual(try boardPixels(staleImage), try boardPixels(noArrowImage), "过期画面保留棋子，同时不留箭头或圈选残影")
        XCTAssertNotEqual(try boardPixels(guidance), try boardPixels(staleImage), "有效指导中的箭头必须真正绘制并在过期后消失")
    }

    /// 与录屏一致的 720 像素长边及 JPEG 0.5；测试数据没有头像、昵称、状态栏等个人信息。
    private func broadcastFrame(boardAtBottom: Side) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "board-template-\(boardAtBottom.rawValue)", withExtension: "png"))
        let board = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let screen = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 2781), format: format).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1280, height: 2781))
            board.draw(in: CGRect(x: 12, y: 722, width: 1256, height: 1393))
        }
        let cgImage = try XCTUnwrap(screen.cgImage)
        let shrunk = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: 720.0 / 2781, y: 720.0 / 2781))
        let context = CIContext(options: [.cacheIntermediates: false])
        let data = try XCTUnwrap(context.jpegRepresentation(of: shrunk, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func boardPixels(_ image: UIImage) throws -> Data {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 12, y: 8, width: 528, height: 584)))
        return try XCTUnwrap(UIImage(cgImage: crop).pngData())
    }
}
