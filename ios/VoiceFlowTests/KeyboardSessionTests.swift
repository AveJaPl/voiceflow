import XCTest

final class KeyboardSessionTests: XCTestCase {
    func testResultOnlyAutoInsertsIntoOriginalDocumentOnce() {
        let now = Date(timeIntervalSince1970: 1000)
        let state = KeyboardSessionSnapshot(id: UUID(), phase: .result, text: "Test", updatedAt: now)
        XCTAssertTrue(state.mayAutoInsert(now: now, requestedAt: now.addingTimeInterval(-4), sameDocument: true, consumed: false))
        XCTAssertFalse(state.mayAutoInsert(now: now, requestedAt: now, sameDocument: false, consumed: false))
        XCTAssertFalse(state.mayAutoInsert(now: now, requestedAt: nil, sameDocument: true, consumed: false))
        XCTAssertFalse(state.mayAutoInsert(now: now, requestedAt: now, sameDocument: true, consumed: true))
        XCTAssertFalse(state.mayAutoInsert(now: now.addingTimeInterval(61), requestedAt: now, sameDocument: true, consumed: false))
        XCTAssertFalse(state.mayAutoInsert(now: now, requestedAt: now.addingTimeInterval(1), sameDocument: true, consumed: false))
    }
    func testDeadRecordingDoesNotLookLive() {
        let now = Date(timeIntervalSince1970: 1000)
        let state = KeyboardSessionSnapshot(id: UUID(), phase: .recording, updatedAt: now)
        XCTAssertTrue(state.isLive(at: now.addingTimeInterval(1)))
        XCTAssertFalse(state.isLive(at: now.addingTimeInterval(4)))
        XCTAssertFalse(state.isLive(at: now.addingTimeInterval(-1)))
        XCTAssertFalse(state.mayAutoInsert(now: now, requestedAt: now, sameDocument: true, consumed: false))
    }
    func testWaveformIsBoundedAndReleasesAfterSpeech() {
        var meter = VoiceMeter()
        for _ in 0..<30 { meter.update(rms: 0.04, delta: 1 / 30) }
        XCTAssertGreaterThan(meter.amplitude, 0.3)
        XCTAssertLessThan(meter.amplitude, 0.7)
        let heights = (0..<25).map { meter.height(index: $0, count: 25, time: 0.5, reducedMotion: false) }
        XCTAssertGreaterThan(Set(heights).count, 20)
        XCTAssertTrue(heights.allSatisfy { $0 >= 2 && $0 <= 20 })
        for _ in 0..<30 { meter.update(rms: 0, delta: 1 / 30) }
        XCTAssertLessThan(meter.amplitude, 0.001)
        meter.update(rms: .nan, delta: 1 / 30)
        XCTAssertTrue(meter.amplitude.isFinite)
    }
}

final class KeyboardContinuousSessionTests: XCTestCase {
    func testHeartbeatDoesNotMakeOldResultFreshAgain() {
        let now = Date(timeIntervalSince1970: 1000)
        var snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .result, text: "Old", updatedAt: now)
        snapshot.resultAt = now.addingTimeInterval(-120)
        snapshot.microphoneReady = true
        snapshot.expiresAt = now.addingTimeInterval(900)
        XCTAssertTrue(snapshot.canStartInPlace(at: now))
        XCTAssertFalse(snapshot.mayAutoInsert(now: now, requestedAt: now.addingTimeInterval(-180), sameDocument: true, consumed: false))
    }

    func testResultDoesNotBlockAnotherUtteranceButExpiredSessionDoes() {
        let now = Date(timeIntervalSince1970: 1000)
        var snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .result, text: "Not inserted", updatedAt: now)
        snapshot.microphoneReady = true
        snapshot.expiresAt = now.addingTimeInterval(1)
        XCTAssertTrue(snapshot.canStartInPlace(at: now))
        XCTAssertFalse(snapshot.canStartInPlace(at: now.addingTimeInterval(1)))
        snapshot.expiresAt = now.addingTimeInterval(900)
        XCTAssertFalse(snapshot.canStartInPlace(at: now.addingTimeInterval(4)))
        snapshot.microphoneReady = false
        XCTAssertFalse(snapshot.canStartInPlace(at: now))
    }

    func testDelayedStartCommandsAreRejected() {
        let now = Date(timeIntervalSince1970: 1000)
        let request = KeyboardSessionRequest(id: UUID(), issuedAt: now)
        XCTAssertTrue(request.isFresh(at: now.addingTimeInterval(1)))
        XCTAssertFalse(request.isFresh(at: now.addingTimeInterval(15)))
        XCTAssertFalse(request.isFresh(at: now.addingTimeInterval(-1)))
    }

    func testIdleMicrophoneDropsBuffersAndNewUtteranceChangesToken() {
        let gate = AudioUtteranceGate()
        XCTAssertNil(gate.get())
        let first = UUID()
        gate.set(first)
        let queuedBufferToken = gate.get()
        gate.set(nil)
        XCTAssertNil(gate.get())
        let next = UUID()
        gate.set(next)
        XCTAssertNotEqual(queuedBufferToken, gate.get())
    }
}

final class KeyboardActivityPolicyTests: XCTestCase {
    func testInitialHandoffHasOneMinuteGrace() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(KeyboardActivityPolicy.deadline(startedAt: start, lastVisibleAt: nil), start.addingTimeInterval(60))
        XCTAssertEqual(KeyboardActivityPolicy.deadline(startedAt: start, lastVisibleAt: start.addingTimeInterval(-1)), start.addingTimeInterval(60))
    }
    func testVisibleKeyboardExtendsSessionAndHiddenKeyboardExpires() {
        let start = Date(timeIntervalSince1970: 1000)
        let visible = start.addingTimeInterval(3600)
        let deadline = KeyboardActivityPolicy.deadline(startedAt: start, lastVisibleAt: visible)
        XCTAssertEqual(deadline, visible.addingTimeInterval(30))
        XCTAssertLessThan(deadline, visible.addingTimeInterval(31))
    }
}
