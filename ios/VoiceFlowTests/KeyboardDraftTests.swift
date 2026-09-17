import XCTest

final class KeyboardDraftTests: XCTestCase {
    func testEditingPersistsAcrossExtensionRestart() {
        let defaults = UserDefaults(suiteName: "draft-test-\(UUID())")!
        var draft = KeyboardDraft(sessionID: UUID(), text: "Pierwszy tekst", accountKey: "account-a")
        draft.replace(with: "Poprawiony tekst 👋")
        draft.save(defaults: defaults)
        XCTAssertEqual(KeyboardDraft.load(defaults: defaults), draft)
        XCTAssertEqual(KeyboardDraft.load(defaults: defaults)?.accountKey, "account-a")
    }
    func testClearRemainsClearedForSameSession() {
        var draft = KeyboardDraft(sessionID: UUID(), text: "Wynik")
        let session = draft.sessionID
        draft.replace(with: "")
        XCTAssertEqual(draft.sessionID, session)
        XCTAssertFalse(draft.canInsertManually)
        XCTAssertFalse(draft.needsHistorySave)
    }
    func testSavingDoesNotConsumeManualInsertionOrDuplicateHistory() {
        var draft = KeyboardDraft(sessionID: UUID(), text: "Tekst")
        XCTAssertTrue(draft.needsHistorySave)
        draft.savedRevision = draft.revision
        XCTAssertTrue(draft.canInsertManually)
        XCTAssertFalse(draft.needsHistorySave)
        draft.replace(with: "Tekst")
        XCTAssertFalse(draft.needsHistorySave)
        draft.replace(with: "Tekst po edycji")
        XCTAssertTrue(draft.needsHistorySave)
        XCTAssertTrue(draft.canInsertManually)
    }
}
