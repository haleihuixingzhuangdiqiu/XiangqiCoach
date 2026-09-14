import XCTest
@testable import XiangqiCoach

final class CoachAnalysisStateTests: XCTestCase {
    func testSameBoardDoesNotRestartSearchAndCompletedResultCanBeRestored() throws {
        var state = CoachAnalysisState()
        let work = try start(&state, position: .standard, now: 10)
        // 遮挡期间不向搜索状态发送取消；即使恢复时重新申请，仍是同一个工作。
        for time in [10.1, 10.4, 10.7] {
            XCTAssertEqual(state.request(position: .standard, now: time), .inFlight)
        }
        let outcome = CoachAnalysisState.Outcome(result: result, error: nil)
        XCTAssertTrue(state.complete(work, outcome: outcome))
        XCTAssertFalse(state.isInFlight)
        for time in [10.8, 11, 15] {
            XCTAssertEqual(state.request(position: .standard, now: time), .completed(outcome))
        }
    }

    func testNewPositionRejectsPreviousCompletion() throws {
        var state = CoachAnalysisState()
        let old = try start(&state, position: .standard, now: 10)
        let next = XiangqiPosition.standard.applying(result.move)
        let current = try start(&state, position: next, now: 10.2)
        XCTAssertNotEqual(old.revision, current.revision)
        XCTAssertFalse(state.complete(old, outcome: .init(result: result, error: nil)))
        XCTAssertEqual(state.request(position: next, now: 10.3), .inFlight)
        XCTAssertTrue(state.complete(current, outcome: .init(result: nil, error: "本局计算失败")))
    }

    func testTimeoutIsTerminalUntilExplicitRetryAndRejectsLateSuccess() throws {
        var state = CoachAnalysisState()
        let old = try start(&state, position: .standard, now: 10)
        XCTAssertNil(state.expire(now: 12.9, timeout: 3))
        let timeout = try XCTUnwrap(state.expire(now: 13, timeout: 3))
        XCTAssertTrue(timeout.error?.contains("超时") == true)
        XCTAssertTrue(state.hasFailure)
        XCTAssertFalse(state.isInFlight)
        XCTAssertFalse(state.complete(old, outcome: .init(result: result, error: nil)))
        XCTAssertEqual(state.request(position: .standard, now: 13.2), .completed(timeout))
        state.reset()
        XCTAssertFalse(state.hasFailure)
        let retry = try start(&state, position: .standard, now: 14)
        XCTAssertNotEqual(retry.revision, old.revision)
        XCTAssertTrue(state.complete(retry, outcome: .init(result: result, error: nil)))
    }

    func testEmptyResultIsCompletionRatherThanPermanentThinking() throws {
        var state = CoachAnalysisState()
        let work = try start(&state, position: .standard, now: 1)
        let outcome = CoachAnalysisState.Outcome(result: nil, error: nil)
        XCTAssertTrue(state.complete(work, outcome: outcome))
        XCTAssertEqual(state.request(position: .standard, now: 2), .completed(outcome))
        XCTAssertFalse(state.isInFlight)
    }

    func testStopOrManualSynchronizationInvalidatesSameBoardWork() throws {
        var state = CoachAnalysisState()
        let old = try start(&state, position: .standard, now: 1)
        state.reset()
        XCTAssertFalse(state.hasWork)
        XCTAssertFalse(state.complete(old, outcome: .init(result: result, error: nil)))
        let next = try start(&state, position: .standard, now: 2)
        XCTAssertNotEqual(next.revision, old.revision)
    }

    private var result: SearchResult {
        let move = XiangqiMove(from: Square(row: 7, column: 7), to: Square(row: 7, column: 4))
        return SearchResult(move: move, score: 10, depth: 16, principalVariation: [move], elapsedMilliseconds: 800, nodesVisited: 1000)
    }

    private func start(_ state: inout CoachAnalysisState, position: XiangqiPosition, now: Double) throws -> CoachAnalysisState.Work {
        guard case let .start(work) = state.request(position: position, now: now) else {
            throw NSError(domain: "CoachAnalysisStateTests", code: 1)
        }
        return work
    }
}
