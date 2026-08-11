import XCTest

/// Testy hardware-free logiki "czy wstawić czekający tekst" — kryterium
/// weryfikacji #2 z zadania PIVOT #2 (docs/plans/ios-voiceflow-app.md §7).
/// `PendingInsert.shouldInsert` jest czystą funkcją (Shared/PendingInsert.swift),
/// bez UIKit/App Group, więc testowana wprost, bez symulatora/urządzenia.
final class PendingInsertTests: XCTestCase {

    func testFreshTextWithinWindowShouldInsert() {
        let now = Date()
        let insertedAt = now.addingTimeInterval(-10) // 10s temu, próg to 60s
        XCTAssertTrue(PendingInsert.shouldInsert(text: "cześć", insertedAt: insertedAt, now: now))
    }

    func testTextRightAtCreationShouldInsert() {
        let now = Date()
        XCTAssertTrue(PendingInsert.shouldInsert(text: "cześć", insertedAt: now, now: now))
    }

    func testStaleTextBeyondWindowShouldNotInsert() {
        let now = Date()
        let insertedAt = now.addingTimeInterval(-61) // tuż za progiem 60s
        XCTAssertFalse(PendingInsert.shouldInsert(text: "cześć", insertedAt: insertedAt, now: now))
    }

    func testTextExactlyAtWindowBoundaryShouldNotInsert() {
        let now = Date()
        let insertedAt = now.addingTimeInterval(-PendingInsert.freshWindow) // dokładnie 60s — próg jest wyłączny
        XCTAssertFalse(PendingInsert.shouldInsert(text: "cześć", insertedAt: insertedAt, now: now))
    }

    func testEmptyTextShouldNotInsert() {
        let now = Date()
        XCTAssertFalse(PendingInsert.shouldInsert(text: "", insertedAt: now, now: now))
    }

    func testNilTextShouldNotInsert() {
        let now = Date()
        XCTAssertFalse(PendingInsert.shouldInsert(text: nil, insertedAt: now, now: now))
    }

    func testNilTimestampShouldNotInsert() {
        XCTAssertFalse(PendingInsert.shouldInsert(text: "cześć", insertedAt: nil, now: Date()))
    }

    func testFutureTimestampShouldNotInsert() {
        // Zegar rozjechany / defensywnie — znacznik z przyszłości nie powinien
        // przejść jako "świeży".
        let now = Date()
        let insertedAt = now.addingTimeInterval(30)
        XCTAssertFalse(PendingInsert.shouldInsert(text: "cześć", insertedAt: insertedAt, now: now))
    }
}
