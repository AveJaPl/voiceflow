import XCTest
@testable import VoiceFlow

/// Historia na Macu musi być czytelna dla reszty projektu.
///
/// Linux i Windows dzielą `src/voiceflow/history.py`: jedna linia JSON na
/// dyktowanie, klucze `timestamp`/`words`/`chars`/`audio_seconds`/
/// `transcription_seconds`/`injected`/`text`. Mac ma własną implementację w
/// Swifcie, więc jedyne, co trzyma te dwa światy razem, to format pliku —
/// i dlatego jest tu testowany wprost. Odpowiednik po stronie Pythona:
/// `tests/test_history.py::test_macos_written_line_is_readable_here`.
final class NotesStoreFormatTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-test-\(UUID().uuidString).jsonl")
    }

    func testZapisujeKluczeWspolneZLinuksem() throws {
        let note = Note(
            finalText: "Dzień dobry państwu.",
            rawText: "dzień dobry panstwu",
            targetBundleID: "com.apple.Safari",
            duration: 2.345
        )

        let line = try XCTUnwrap(NotesStore.encodeLine(note))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["text"] as? String, "Dzień dobry państwu.")
        XCTAssertEqual(object["words"] as? Int, 3, "liczone jak w Pythonie: text.split()")
        XCTAssertEqual(object["chars"] as? Int, 20)
        XCTAssertEqual(object["audio_seconds"] as? Double, 2.35, "zaokrąglone do 2 miejsc jak na Linuksie")
        XCTAssertEqual(object["injected"] as? Bool, true)
        XCTAssertNotNil(object["timestamp"] as? String)
        XCTAssertTrue(line.hasSuffix("\n"), "JSONL: dokładnie jedna linia na wpis")
    }

    func testNieudaneWstrzyknieciePamietaneJakoNieudane() throws {
        let note = Note(
            finalText: "tekst",
            rawText: "tekst",
            targetBundleID: nil,
            duration: 1,
            injected: false
        )

        let line = try XCTUnwrap(NotesStore.encodeLine(note))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(line.data(using: .utf8))) as? [String: Any]
        )

        XCTAssertEqual(object["injected"] as? Bool, false)
        XCTAssertNil(object["target_bundle_id"], "brak aplikacji docelowej = brak klucza, nie null")
    }

    func testZapisIOdczytSaSymetryczne() throws {
        let note = Note(
            finalText: "raz dwa trzy",
            rawText: "raz dwa trzy",
            targetBundleID: "com.example.app",
            duration: 3.5
        )

        let line = try XCTUnwrap(NotesStore.encodeLine(note))
        let decoded = try XCTUnwrap(NotesStore.decodeLine(line))

        XCTAssertEqual(decoded.id, note.id)
        XCTAssertEqual(decoded.finalText, note.finalText)
        XCTAssertEqual(decoded.rawText, note.rawText)
        XCTAssertEqual(decoded.targetBundleID, note.targetBundleID)
        XCTAssertEqual(decoded.duration, 3.5, accuracy: 0.001)
    }

    func testUszkodzonaLiniaNiePsujeCalejHistorii() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let good = try XCTUnwrap(NotesStore.encodeLine(
            Note(finalText: "dobra", rawText: "dobra", targetBundleID: nil, duration: 1)
        ))
        try Data(("{ to nie jest json\n" + good).utf8).write(to: url)

        let store = NotesStore(fileURL: url)

        XCTAssertEqual(store.notes.count, 1, "zła linia pomijana, reszta historii zostaje")
        XCTAssertEqual(store.notes.first?.finalText, "dobra")
    }

    func testKolejneDyktowaniaDopisujaSieOsobno() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(fileURL: url)

        store.add(Note(finalText: "pierwsze", rawText: "pierwsze", targetBundleID: nil, duration: 1))
        store.add(Note(finalText: "drugie", rawText: "drugie", targetBundleID: nil, duration: 1))

        let reloaded = NotesStore(fileURL: url)
        XCTAssertEqual(reloaded.notes.map(\.finalText), ["drugie", "pierwsze"], "najnowsze pierwsze")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            contents.split(separator: "\n").count, 2,
            "dwa dyktowania to dwie linie — nie jedna sklejona"
        )
    }
}
