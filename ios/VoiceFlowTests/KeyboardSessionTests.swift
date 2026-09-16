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
