import XCTest
@testable import XiangqiCoach

final class PiPStartStateTests: XCTestCase {
    func testDelayedReadinessCompletesOneIntentWithoutFixedDelay() {
        var state = PiPStartState()
        state.request(now: 10)
        XCTAssertNil(state.nextAction(isReady: false, isForeground: true, now: 10.7))
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 12), .start)
        state.request(now: 12.1)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 12.2))
        XCTAssertTrue(state.didStart())
        XCTAssertEqual(state.phase, .active)
    }

    func testConfirmationPanelAndBackgroundDoNotConsumeStart() {
        var state = PiPStartState()
        state.request(now: 0)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: false, now: 0.1))
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 2), .start)
    }

    func testInlineAutomaticStartCanClaimWaitingIntent() {
        var state = PiPStartState()
        state.request(now: 0)
        state.willStart(now: 1)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 1))
        XCTAssertTrue(state.didStart())
    }

    func testCancelledStartRejectsLateSystemCallback() {
        var state = PiPStartState()
        state.request(now: 1)
        _ = state.nextAction(isReady: true, isForeground: true, now: 1.1)
        state.stop()
        state.willStart(now: 1)
        XCTAssertFalse(state.didStart())
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 2))
        XCTAssertFalse(state.wantsStart)
    }

    func testUserClosingDoesNotReopenUntilExplicitResume() {
        var state = PiPStartState()
        state.request(now: 1)
        XCTAssertTrue(state.didStart())
        state.stop()
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 2))
        state.request(now: 3)
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 3), .start)
    }

    func testUnavailableOrMissingCallbackTimesOutWithoutAutomaticLoop() {
        for isReady in [false, true] {
            var state = PiPStartState()
            state.request(now: 1)
            _ = state.nextAction(isReady: isReady, isForeground: true, now: 1)
            XCTAssertEqual(state.nextAction(isReady: false, isForeground: true, now: 11), .timedOut)
            XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 12))
            XCTAssertFalse(state.didStart())
            state.request(now: 20)
            XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 20), .start)
        }
    }

    func testLateReadinessReceivesFullSystemStartBudget() {
        for readyAt in [9.9, 40.0] {
            var state = PiPStartState()
            state.request(now: 0)
            XCTAssertNil(state.nextAction(isReady: false, isForeground: false, now: readyAt - 0.1))
            XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: readyAt), .start)
            XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: readyAt + 0.5))
            XCTAssertTrue(state.didStart())
        }
    }

    func testDelayedInlineStartAlsoReceivesFullCallbackBudget() {
        var state = PiPStartState()
        state.request(now: 0)
        state.willStart(now: 9.9)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 10.1))
        XCTAssertTrue(state.didStart())
    }

    func testRestartWaitsForPreviousStopCallbackWithoutLosingNewIntent() {
        var state = PiPStartState()
        state.request(now: 0)
        XCTAssertTrue(state.didStart())
        state.stop(now: 1, awaitsCallback: true)
        state.request(now: 1.1)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 1.2))
        XCTAssertFalse(state.didStart())
        state.willStop(now: 1.3)
        state.didStop(now: 1.4)
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 1.4), .start)
        XCTAssertTrue(state.didStart())
    }

    func testSecondStopCancelsQueuedRestart() {
        var state = PiPStartState()
        state.request(now: 0)
        state.stop(now: 1, awaitsCallback: true)
        state.request(now: 1.1)
        state.stop(now: 1.2, awaitsCallback: true)
        state.didStop(now: 2)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 2))
        XCTAssertFalse(state.wantsStart)
    }

    func testNewDisplaySourceRearmsExistingIntentButNotCancelledSession() {
        var state = PiPStartState()
        state.request(now: 0)
        XCTAssertTrue(state.didStart())
        state.replaceSource(now: 10)
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 10.5), .start)
        state.stop()
        state.replaceSource(now: 20)
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 20.5))
    }

    func testStopWithoutCallbackExpiresAndExplicitRetryRemainsPossible() {
        var state = PiPStartState()
        state.stop(now: 1, awaitsCallback: true)
        state.request(now: 2)
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 11), .timedOut)
        XCTAssertFalse(state.wantsStart)
        state.request(now: 12)
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 12), .start)
    }

    func testFailureNeedsExplicitRetry() {
        var state = PiPStartState()
        state.request(now: 1)
        state.fail()
        XCTAssertNil(state.nextAction(isReady: true, isForeground: true, now: 2))
        state.request(now: 3)
        XCTAssertEqual(state.nextAction(isReady: true, isForeground: true, now: 3), .start)
    }
}
