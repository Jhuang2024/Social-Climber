import XCTest
@testable import SocialClimber

/// Tests the recording state machine: every legal transition, rejection of
/// illegal ones, and the full happy-path + retry lifecycles.
final class AudioCaptureStateMachineTests: XCTestCase {

    func testStartsIdle() {
        let machine = AudioCaptureStateMachine()
        XCTAssertEqual(machine.state, .idle)
    }

    func testHappyPathLifecycle() {
        var m = AudioCaptureStateMachine()
        XCTAssertTrue(m.transition(to: .recording))
        XCTAssertTrue(m.transition(to: .processing))
        XCTAssertTrue(m.transition(to: .completed))
        XCTAssertEqual(m.state, .completed)
    }

    func testPauseResumeLifecycle() {
        var m = AudioCaptureStateMachine()
        m.transition(to: .recording)
        XCTAssertTrue(m.transition(to: .paused))
        XCTAssertTrue(m.transition(to: .recording)) // resume
        XCTAssertTrue(m.transition(to: .processing))
        XCTAssertTrue(m.transition(to: .completed))
    }

    func testInterruptionRecovery() {
        var m = AudioCaptureStateMachine()
        m.transition(to: .recording)
        XCTAssertTrue(m.transition(to: .interrupted))
        XCTAssertTrue(m.transition(to: .recording)) // auto-resume
        XCTAssertTrue(m.transition(to: .processing))
        XCTAssertTrue(m.transition(to: .completed))
    }

    func testRetryFromFailed() {
        var m = AudioCaptureStateMachine()
        m.transition(to: .recording)
        m.transition(to: .processing)
        XCTAssertTrue(m.transition(to: .failed))
        // Retry transcription.
        XCTAssertTrue(m.transition(to: .processing))
        XCTAssertTrue(m.transition(to: .completed))
    }

    func testReprocessFromCompleted() {
        var m = AudioCaptureStateMachine(state: .completed)
        XCTAssertTrue(m.transition(to: .processing))
        XCTAssertTrue(m.transition(to: .completed))
    }

    func testIllegalTransitionsRejected() {
        var m = AudioCaptureStateMachine()
        // Can't jump straight from idle to completed.
        XCTAssertFalse(m.transition(to: .completed))
        XCTAssertEqual(m.state, .idle)
        // Can't go idle → processing.
        XCTAssertFalse(m.transition(to: .processing))
        XCTAssertEqual(m.state, .idle)
    }

    func testNoOpTransitionAllowed() {
        var m = AudioCaptureStateMachine(state: .recording)
        XCTAssertTrue(m.transition(to: .recording))
        XCTAssertEqual(m.state, .recording)
    }

    func testCompletedIsTerminal() {
        XCTAssertTrue(AudioCaptureState.completed.isTerminal)
        XCTAssertTrue(AudioCaptureState.failed.isTerminal)
        XCTAssertFalse(AudioCaptureState.recording.isTerminal)
    }

    func testEveryFailureIsRetryable() {
        for failure in AudioCaptureFailure.allCases {
            XCTAssertTrue(failure.isRetryable, "\(failure) should be retryable")
            XCTAssertFalse(failure.message.isEmpty)
        }
    }
}
