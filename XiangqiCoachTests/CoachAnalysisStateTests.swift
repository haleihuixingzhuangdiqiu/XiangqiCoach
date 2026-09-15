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

    func testFirstTimeoutRetriesOnlyAfterCooldownAndFreshBoardRequest() throws {
        var state = CoachAnalysisState()
        let old = try start(&state, position: .standard, now: 10)
        XCTAssertNil(state.expire(now: 12.9, timeout: 3))
        let timeout = try XCTUnwrap(state.expire(now: 13, timeout: 3))
        XCTAssertTrue(timeout.error?.contains("自动重试一次") == true)
        XCTAssertTrue(state.hasFailure)
        XCTAssertFalse(state.isInFlight)
        XCTAssertFalse(state.complete(old, outcome: .init(result: result, error: nil)))
        for now in [12.0, 13.0, 13.999, Double.infinity, Double.nan] {
            XCTAssertEqual(state.request(position: .standard, now: now), .completed(timeout))
        }
        // 冷却结束没有新鲜已确认画面 request 时，计时器不会自行重启搜索。
        XCTAssertNil(state.expire(now: 14, timeout: 3))
        XCTAssertFalse(state.isInFlight)
        let retry = try start(&state, position: .standard, now: 14)
        XCTAssertGreaterThan(retry.revision, old.revision)
        XCTAssertFalse(state.hasFailure)
        XCTAssertEqual(state.request(position: .standard, now: 14.1), .inFlight)
        XCTAssertFalse(state.complete(old, outcome: .init(result: result, error: nil)))
        let success = CoachAnalysisState.Outcome(result: result, error: nil)
        XCTAssertTrue(state.complete(retry, outcome: success))
        XCTAssertEqual(state.request(position: .standard, now: 100), .completed(success))
    }

    func testSecondTimeoutIsTerminalAndResetRestoresOneRetryBudget() throws {
        var state = CoachAnalysisState()
        let first = try start(&state, position: .standard, now: 10)
        _ = state.expire(now: 13, timeout: 3)
        let retry = try start(&state, position: .standard, now: 14)
        XCTAssertNil(state.expire(now: 16.999, timeout: 3))
        let finalFailure = try XCTUnwrap(state.expire(now: 17, timeout: 3))
        XCTAssertTrue(finalFailure.error?.contains("请重新开启录屏") == true)
        XCTAssertFalse(state.complete(first, outcome: .init(result: result, error: nil)))
        XCTAssertFalse(state.complete(retry, outcome: .init(result: result, error: nil)))
        for now in [18.0, 30.0, 100.0] {
            XCTAssertNil(state.expire(now: now, timeout: 3))
            XCTAssertEqual(state.request(position: .standard, now: now), .completed(finalFailure))
        }
        state.reset()
        let reset = try start(&state, position: .standard, now: 101)
        XCTAssertGreaterThan(reset.revision, retry.revision)
        let firstFailureAgain = try XCTUnwrap(state.expire(now: 104, timeout: 3))
        XCTAssertTrue(firstFailureAgain.error?.contains("自动重试一次") == true)
        XCTAssertNoThrow(try start(&state, position: .standard, now: 105))
    }

    func testNewPositionResetsRetryBudgetAndRejectsTimedOutPositionResult() throws {
        var state = CoachAnalysisState()
        _ = try start(&state, position: .standard, now: 1)
        _ = state.expire(now: 4, timeout: 3)
        let oldRetry = try start(&state, position: .standard, now: 5)
        _ = state.expire(now: 8, timeout: 3)
        let next = XiangqiPosition.standard.applying(result.move)
        let newWork = try start(&state, position: next, now: 9)
        XCTAssertGreaterThan(newWork.revision, oldRetry.revision)
        XCTAssertFalse(state.complete(oldRetry, outcome: .init(result: result, error: nil)))
        let failure = try XCTUnwrap(state.expire(now: 12, timeout: 3))
        XCTAssertTrue(failure.error?.contains("自动重试一次") == true)
        XCTAssertNoThrow(try start(&state, position: next, now: 13))
    }

    func testEngineFailuresAndTerminalPositionsNeverScheduleAutomaticRetry() throws {
        for error in [nil, "模型加载失败，请重新开启录屏", "引擎响应超时"] as [String?] {
            var state = CoachAnalysisState()
            let work = try start(&state, position: .standard, now: 10)
            let completed = CoachAnalysisState.Outcome(result: nil, error: error)
            XCTAssertTrue(state.complete(work, outcome: completed))
            XCTAssertNil(state.expire(now: 20, timeout: 3))
            XCTAssertEqual(state.request(position: .standard, now: 30), .completed(completed))
            XCTAssertFalse(state.isInFlight)
        }
    }

    func testEmptyResultIsCompletionRatherThanPermanentThinking() throws {
        var state = CoachAnalysisState()
        let work = try start(&state, position: .standard, now: 1)
        let outcome = CoachAnalysisState.Outcome(result: nil, error: nil)
        XCTAssertTrue(state.complete(work, outcome: outcome))
        XCTAssertEqual(state.request(position: .standard, now: 2), .completed(outcome))
        XCTAssertFalse(state.isInFlight)
    }

    func testStopOrRecognitionResetInvalidatesSameBoardWork() throws {
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
