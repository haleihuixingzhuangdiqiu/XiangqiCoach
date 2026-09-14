import CryptoKit
import Foundation
import XCTest
@testable import XiangqiCoach

final class PikafishEngineTests: XCTestCase {
    func testFENPreservesBothSidesAndConvertsHorseElephantAndTurn() throws {
        for side in Side.allCases {
            var position = XiangqiPosition.standard
            position.sideToMove = side
            let encoded = XiangqiEngine.engineFEN(for: position)
            XCTAssertTrue(encoded.hasPrefix("rnbakabnr/"))
            XCTAssertTrue(encoded.hasSuffix(side == .red ? " w - - 0 1" : " b - - 0 1"))
            XCTAssertEqual(try XCTUnwrap(XiangqiPosition(fen: encoded)), position)
        }
    }

    func testICCSMappingMatchesScreenIndependentBoardCoordinates() {
        XCTAssertEqual(XiangqiEngine.move(fromICCS: "h2e2"), XiangqiMove(
            from: Square(row: 7, column: 7), to: Square(row: 7, column: 4)
        ))
        XCTAssertEqual(XiangqiEngine.move(fromICCS: "b9c7"), XiangqiMove(
            from: Square(row: 0, column: 1), to: Square(row: 2, column: 2)
        ))
        for invalid in ["", "0000", "(none)", "a0j1", "a0a0", "a0b10", "A0B1"] {
            XCTAssertNil(XiangqiEngine.move(fromICCS: invalid))
        }
    }

    func testFindsHangingRookAndDoesNotTradeRookForDefendedPawn() throws {
        let engine = XiangqiEngine()
        let hanging = try position("4k4/9/9/9/4p4/9/2r6/2R6/9/4K4 r")
        let capture = try XCTUnwrap(engine.search(position: hanging, timeLimit: 0.25, maximumDepth: 32), engine.lastError ?? "")
        XCTAssertEqual(capture.move.iccs(), "c2c3")

        let poisoned = try position("4k4/9/9/9/r3p4/p8/R8/9/9/4K4 r")
        let safe = try XCTUnwrap(engine.search(position: poisoned, timeLimit: 0.25, maximumDepth: 32), engine.lastError ?? "")
        XCTAssertNotEqual(safe.move.iccs(), "a3a4", "不能贪吃被车保护的卒而白送一辆车")
        XCTAssertTrue(poisoned.legalMoves().contains(safe.move))
    }

    func testEscapesCheckAndFindsMateInOne() throws {
        let engine = XiangqiEngine()
        let checked = try position("4k4/9/9/9/9/4P4/9/9/9/r3K4 r")
        XCTAssertTrue(checked.isInCheck(.red))
        let escape = try XCTUnwrap(engine.search(position: checked, timeLimit: 0.2, maximumDepth: 32), engine.lastError ?? "")
        XCTAssertEqual(escape.move.iccs(), "e0e1")
        XCTAssertFalse(checked.applying(escape.move).isInCheck(.red))

        let mating = try position("4k4/R3a4/4R4/9/9/9/9/9/9/4K4 r")
        let mate = try XCTUnwrap(engine.search(position: mating, timeLimit: 0.2, maximumDepth: 32), engine.lastError ?? "")
        XCTAssertEqual(mate.move.iccs(), "a8a9")
        XCTAssertGreaterThan(mate.score, 90_000)
        XCTAssertTrue(mating.applying(mate.move).legalMoves().isEmpty)
    }

    func testOpeningUsesNNUEAndReportsRealSearchWorkWithinBudget() throws {
        let engine = XiangqiEngine()
        let result = try XCTUnwrap(engine.search(position: .standard, timeLimit: 0.2), engine.lastError ?? "")
        XCTAssertTrue(XiangqiPosition.standard.legalMoves().contains(result.move))
        XCTAssertGreaterThan(result.depth, 5, "成熟引擎不能仍被旧原型的五层上限限制")
        XCTAssertGreaterThan(result.nodesVisited, 100)
        XCTAssertLessThan(result.elapsedMilliseconds, 1_000)
        XCTAssertEqual(result.principalVariation.first, result.move)
        var linePosition = XiangqiPosition.standard
        for move in result.principalVariation {
            XCTAssertTrue(linePosition.legalMoves().contains(move))
            linePosition = linePosition.applying(move)
        }
    }

    func testMissingNetworkReportsErrorWithoutFallbackMove() {
        let engine = XiangqiEngine(networkURL: URL(fileURLWithPath: "/missing-test-network/pikafish.nnue"))
        XCTAssertNil(engine.search(position: .standard))
        XCTAssertTrue(engine.lastError?.contains("模型") == true)
    }

    func testInvalidNativePositionReportsErrorWithoutTerminatingApp() throws {
        let engine = XiangqiEngine()
        let faceToFaceKings = try position("4k4/9/9/9/9/9/9/9/9/4K4 r")
        XCTAssertFalse(faceToFaceKings.legalMoves().isEmpty)
        XCTAssertNil(engine.search(position: faceToFaceKings))
        XCTAssertNotNil(engine.lastError)
    }

    func testCancelBeforeInitializationAndDuringSearchDoesNotPoisonNextSearch() throws {
        let engine = XiangqiEngine()
        engine.cancel()
        XCTAssertNotNil(engine.search(position: .standard, timeLimit: 0.03, maximumDepth: 1))
        let cancellation = expectation(description: "旧局面搜索被打断")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            engine.cancel()
            cancellation.fulfill()
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(engine.search(position: .standard, timeLimit: 3))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
        XCTAssertNil(engine.lastError, "主动取消不应冒充引擎错误")
        wait(for: [cancellation], timeout: 1)
        let resumed = try XCTUnwrap(engine.search(position: .standard, timeLimit: 0.05, maximumDepth: 3), engine.lastError ?? "")
        XCTAssertTrue(XiangqiPosition.standard.legalMoves().contains(resumed.move))
    }

    func testZeroBudgetReportsExplicitFailureInsteadOfFabricatedDepthOrScore() {
        let engine = XiangqiEngine()
        XCTAssertNil(engine.search(position: .standard, timeLimit: 0))
        XCTAssertNotNil(engine.lastError)
        XCTAssertNil(engine.search(position: .standard, maximumDepth: 0))
        XCTAssertNotNil(engine.lastError)
    }

    func testBundledNNUEIsByteIdenticalToProAndOfficialRelease() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "pikafish", withExtension: "nnue", subdirectory: "Pikafish"))
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44_880_002)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "9b2ce59b760c26f284b9fcadd091fa789d9fd4e8c1dd71ffbd42212503a13e95")
    }

    func testDepthTwelveOpeningMatchesProReferenceSearch() throws {
        let engine = XiangqiEngine()
        let result = try XCTUnwrap(engine.search(position: .standard, timeLimit: 5, maximumDepth: 12), engine.lastError ?? "")
        XCTAssertEqual(result.depth, 12)
        XCTAssertEqual(result.nodesVisited, 59_716)
        XCTAssertEqual(result.move.iccs(), "g3g4")
        XCTAssertEqual(result.principalVariation.map { $0.iccs() }, [
            "g3g4", "h7e7", "b2e2", "h9g7", "h0g2", "b9c7", "b0c2", "a9b9", "a0b0", "i9h9", "b0b6"
        ])
    }

    func testSearchReceivesLegalHistoryAndRejectsDifferentBoard() throws {
        let engine = XiangqiEngine()
        let moves = try ["b0c2", "b9c7"].map { try XCTUnwrap(XiangqiEngine.move(fromICCS: $0)) }
        let history = AnalysisHistory(root: .standard, moves: moves)
        let current = moves.reduce(XiangqiPosition.standard) { $0.applying($1) }
        let result = try XCTUnwrap(engine.search(position: current, timeLimit: 0.1, maximumDepth: 5, history: history), engine.lastError ?? "")
        XCTAssertTrue(current.legalMoves().contains(result.move))
        XCTAssertNil(engine.search(position: .standard, history: history))
        XCTAssertTrue(engine.lastError?.contains("历史") == true)
    }

    func testNativeHistoryKeepsRepetitionAndRejectsIllegalMoves() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "pikafish", withExtension: "nnue", subdirectory: "Pikafish"))
        let native = XQPikafishEngine(networkPath: url.path)
        XCTAssertTrue(native.ready, native.lastError ?? "")
        let fen = XiangqiEngine.engineFEN(for: .standard)
        let cycle = ["b0c2", "b9c7", "c2b0", "c7b9", "b0c2", "b9c7", "c2b0", "c7b9"]
        let repeated = try XCTUnwrap(native.search(fen: fen, moves: cycle, milliseconds: 200, maximumDepth: 6, nodeLimit: 0, revision: 0), native.lastError ?? "")
        // 保留往返历史时为 2079 节点，丢弃历史则为 1947；根节点依然可选择继续走。
        XCTAssertEqual(repeated.nodes, 2_079)
        XCTAssertEqual(repeated.score, 75)
        XCTAssertNotNil(XiangqiEngine.move(fromICCS: repeated.bestMove))
        XCTAssertNil(native.search(fen: fen, moves: ["a0a9"], milliseconds: 100, maximumDepth: 3, nodeLimit: 0, revision: 0))
        XCTAssertTrue(native.lastError?.contains("历史") == true)
        XCTAssertNotNil(native.search(fen: fen, milliseconds: 100, maximumDepth: 3, nodeLimit: 0, revision: 0))
        XCTAssertNil(native.lastError)
    }

    private func position(_ fen: String) throws -> XiangqiPosition {
        try XCTUnwrap(XiangqiPosition(fen: fen))
    }
}
