import UIKit
import XCTest
@testable import XiangqiCoach

final class CoachBoardRendererTests: XCTestCase {
    private let grid = CGRect(x: 20, y: 30, width: 400, height: 450)

    func testDefaultPieceAndWoodAssetsArePackaged() {
        XCTAssertTrue(CoachBoardRenderer.hasCompleteProAssets, "需要打包 ProUI 的 14 个棋子及无品牌木纹 PNG")
    }

    func testLargerBoardPreservesSquareCellsAndCanvasMargins() {
        let grid = CoachBoardRenderer.grid
        XCTAssertEqual(grid.width / 8, grid.height / 9, accuracy: 0.001)
        XCTAssertGreaterThan(grid.width, 408)
        XCTAssertGreaterThan(grid.height, 459)
        let pieceRadius = grid.width / 8 * 0.91 / 2
        XCTAssertGreaterThan(grid.minX - pieceRadius, 0)
        XCTAssertGreaterThan(grid.minY - pieceRadius, 0)
        XCTAssertLessThan(grid.maxX + pieceRadius, CoachBoardRenderer.canvasSize.width)
        XCTAssertLessThan(grid.maxY + pieceRadius + 10, CoachBoardRenderer.canvasSize.height)
    }

    func testRedAndBlackOrientationRotatesBothAxes() {
        let red = CoachBoardGeometry(grid: grid, boardAtBottom: .red)
        let black = CoachBoardGeometry(grid: grid, boardAtBottom: .black)
        let topLeft = Square(row: 0, column: 0)
        let bottomRight = Square(row: 9, column: 8)
        XCTAssertEqual(red.point(for: topLeft), CGPoint(x: 20, y: 30))
        XCTAssertEqual(red.point(for: bottomRight), CGPoint(x: 420, y: 480))
        XCTAssertEqual(black.point(for: topLeft), red.point(for: bottomRight))
        XCTAssertEqual(black.point(for: bottomRight), red.point(for: topLeft))
        for row in 0..<10 {
            for column in 0..<9 {
                let square = Square(row: row, column: column)
                let rotated = Square(row: 9 - row, column: 8 - column)
                XCTAssertEqual(black.point(for: square), red.point(for: rotated))
            }
        }
    }

    func testArrowTipAlwaysMatchesDestinationInBothOrientations() {
        let moves = [
            XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4)),
            XiangqiMove(from: Square(row: 6, column: 0), to: Square(row: 5, column: 0)),
            XiangqiMove(from: Square(row: 9, column: 1), to: Square(row: 7, column: 2)),
        ]
        for side in Side.allCases {
            let geometry = CoachBoardGeometry(grid: grid, boardAtBottom: side)
            for move in moves {
                let points = geometry.arrowPoints(for: move)
                XCTAssertEqual(points.count, 7)
                XCTAssertEqual(points[3], geometry.point(for: move.to))
                XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            }
        }
    }

    func testInvalidArrowsAreRejected() {
        let geometry = CoachBoardGeometry(grid: grid, boardAtBottom: .red)
        XCTAssertTrue(geometry.arrowPoints(for: XiangqiMove(
            from: Square(row: 0, column: 0), to: Square(row: 0, column: 0)
        )).isEmpty)
        XCTAssertTrue(geometry.arrowPoints(for: XiangqiMove(
            from: Square(row: -1, column: 0), to: Square(row: 0, column: 0)
        )).isEmpty)
        XCTAssertTrue(geometry.arrowPoints(for: XiangqiMove(
            from: Square(row: 0, column: 0), to: Square(row: 10, column: 0)
        )).isEmpty)
    }

    func testRecommendationRequiresRealPositionAndLegalMove() {
        let move = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        var state = CoachOverlayState(suggestedMove: move)
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
        state.position = .standard
        XCTAssertEqual(CoachBoardRenderer.displayedMove(for: state), move)
        state.position = XiangqiPosition.standard.applying(move)
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
        state.position = .standard
        state.suggestedMove = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 9))
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
    }

    func testThinkingKeepsStatusAndDoesNotOfferTapInstructions() {
        let state = CoachOverlayState(
            title: "轮到你 · 红方", move: "正在思考", detail: "棋盘已确认，正在计算下一步", accent: .systemOrange,
            position: .standard
        )
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
        XCTAssertEqual(CoachBoardRenderer.guidanceText(for: state), state.move)
        XCTAssertEqual(CoachBoardRenderer.guidanceDetail(for: state), state.detail)
        XCTAssertEqual(CoachBoardRenderer.boardCaption(for: state), "实时棋局")
        XCTAssertTrue(CoachBoardRenderer.instructionLines(for: state).isEmpty)
    }

    func testStaleBoardSuppressesEvenLegalOldArrowAndText() {
        let move = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        var state = CoachOverlayState(
            title: "等待更新画面", move: "炮二平五", detail: "先点圈选棋子，再点箭头落点", accent: .systemOrange,
            position: .standard, suggestedMove: move, boardAtBottom: .red, boardIsCurrent: false
        )
        XCTAssertTrue(XiangqiPosition.standard.legalMoves().contains(move))
        XCTAssertNil(CoachBoardRenderer.displayedMove(for: state))
        XCTAssertEqual(CoachBoardRenderer.boardCaption(for: state), "上次确认局面")
        XCTAssertEqual(CoachBoardRenderer.guidanceText(for: state), "等待棋盘更新")
        XCTAssertFalse(CoachBoardRenderer.guidanceDetail(for: state).contains("先点"))
        XCTAssertTrue(CoachBoardRenderer.instructionLines(for: state).isEmpty)
        // 即便调用方已经清掉 move 对象，旧的文字指令也不能继续显示。
        state.suggestedMove = nil
        XCTAssertEqual(CoachBoardRenderer.guidanceText(for: state), "等待棋盘更新")
        XCTAssertTrue(CoachBoardRenderer.instructionLines(for: state).isEmpty)
    }

    @MainActor
    func testThinkingAndStaleKeepIdenticalConfirmedBoardPixels() throws {
        let thinking = CoachOverlayState(
            title: "轮到你 · 红方", move: "正在思考", detail: "棋盘已确认，正在计算下一步", accent: .systemOrange,
            position: .standard
        )
        var stale = thinking
        stale.title = "等待更新画面"
        stale.boardIsCurrent = false
        stale.suggestedMove = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        let thinkingImage = CoachBoardRenderer.image(for: thinking)
        let staleImage = CoachBoardRenderer.image(for: stale)
        let waitingImage = CoachBoardRenderer.image(for: CoachOverlayState(move: "正在思考"))
        let boardRect = CGRect(x: 12, y: 8, width: 528, height: 584)
        func boardPixels(_ image: UIImage) throws -> Data {
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: boardRect))
            return try XCTUnwrap(UIImage(cgImage: crop).pngData())
        }
        XCTAssertEqual(try boardPixels(thinkingImage), try boardPixels(staleImage), "思考及过期状态都保留已确认棋盘，不画旧箭头")
        XCTAssertNotEqual(try boardPixels(thinkingImage), try boardPixels(waitingImage), "有局面时不能退回白底等待画面")
        for (name, image) in [("图形指导-思考中保留棋盘", thinkingImage), ("图形指导-上次确认局面", staleImage)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testRenderVisualAcceptanceAttachments() {
        XCTAssertTrue(CoachBoardRenderer.hasCompleteProAssets)
        let redMove = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        let red = CoachOverlayState(
            title: "轮到你 · 红方", move: "炮二平五", detail: "已识别 · 建议走法", accent: .systemGreen,
            position: .standard, suggestedMove: redMove, boardAtBottom: .red
        )
        var blackPosition = XiangqiPosition.standard
        blackPosition.sideToMove = .black
        let black = CoachOverlayState(
            title: "轮到你 · 黑方", move: "马二进三", detail: "已识别 · 建议走法", accent: .systemGreen,
            position: blackPosition,
            suggestedMove: XiangqiMove(from: Square(row: 0, column: 1), to: Square(row: 2, column: 2)),
            boardAtBottom: .black
        )
        let waiting = CoachOverlayState(
            title: "录屏已连接", move: "正在寻找棋盘", detail: "切回天天象棋，让完整棋盘停稳", accent: .systemOrange
        )
        for (name, state) in [("图形指导-红方", red), ("图形指导-黑方", black), ("图形指导-等待识别", waiting)] {
            let image = CoachBoardRenderer.image(for: state)
            XCTAssertEqual(image.size, CoachBoardRenderer.canvasSize)
            XCTAssertEqual(image.scale, 1)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
