import XCTest
@testable import VoiceFlow

/// Odpowiednik tests/test_claudeusage.py — te same reguły, te same progi.
/// Obie platformy karmią jedną tablicę, więc liczby muszą się zgadzać co do
/// sztuki niezależnie od tego, na czym kto siedzi.
final class ClaudeUsageTests: XCTestCase {

    private let snapshot: [String: Any] = [
        "session_name": "Audyt projektu",
        "cwd": "/Users/wojtek/projects/tajny-klient",
        "cost": ["total_cost_usd": 190.25],
        "rate_limits": [
            "five_hour": ["used_percentage": 57.99999, "resets_at": 1783881000] as [String: Any],
            "seven_day": ["used_percentage": 5, "resets_at": 1784469600] as [String: Any],
        ],
    ]

    // MARK: - Snapshot paska statusu

    func testCzytaObaOknaIZaokragla() throws {
        let parsed = try XCTUnwrap(
            ClaudeUsageParser.percentages(statusline: snapshot, ageSeconds: 0)
        )

        XCTAssertEqual(parsed.fiveHour, 58)
        XCTAssertEqual(parsed.sevenDay, 5)
        XCTAssertEqual(parsed.resetsAt, 1783881000)
    }

    func testNieswiezySnapshotToNilANieStaraLiczba() {
        XCTAssertNil(
            ClaudeUsageParser.percentages(statusline: snapshot, ageSeconds: 7 * 3600),
            "wczorajsza liczba pokazana jako dzisiejsza jest gorsza niż brak kafelka"
        )
        XCTAssertNotNil(
            ClaudeUsageParser.percentages(statusline: snapshot, ageSeconds: 3600)
        )
    }

    func testProcentySaPrzycinane() throws {
        let document: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 140],
            "seven_day": ["used_percentage": -3],
        ]]

        let parsed = try XCTUnwrap(
            ClaudeUsageParser.percentages(statusline: document, ageSeconds: 0)
        )

        XCTAssertEqual(parsed.fiveHour, 100)
        XCTAssertEqual(parsed.sevenDay, 0)
    }

    func testZmienionyKsztaltDajeNilZamiastAwarii() {
        XCTAssertNil(ClaudeUsageParser.percentages(
            statusline: ["rate_limits": "kiedyś to była mapa"], ageSeconds: 0
        ))
        XCTAssertNil(ClaudeUsageParser.percentages(statusline: [:], ageSeconds: 0))
    }

    // MARK: - Linie transkryptu

    private func line(
        requestID: String,
        timestamp: String = "2026-08-14T10:00:00.000Z",
        output: Int = 50
    ) -> Data {
        let entry: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "requestId": requestID,
            "message": ["usage": [
                "input_tokens": 10,
                "cache_creation_input_tokens": 100,
                "cache_read_input_tokens": 1000,
                "output_tokens": output,
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    func testLiczyWejscieZCacheIWyjscie() throws {
        var seen: Set<String> = []

        let counted = try XCTUnwrap(ClaudeUsageParser.tokens(
            inLine: line(requestID: "req-1"), cutoffISO: "2026-08-14T00:00:00", seen: &seen
        ))

        XCTAssertEqual(counted.input, 1110)
        XCTAssertEqual(counted.output, 50)
    }

    func testJednaOdpowiedzWKilkuLiniachLiczySieRaz() {
        // Zmierzono w prawdziwym transkrypcie: ta sama odpowiedź (requestId)
        // leży w trzech liniach z identycznym usage. Bez deduplikacji wszystko
        // liczyłoby się potrójnie.
        var seen: Set<String> = []
        let cutoff = "2026-08-14T00:00:00"

        XCTAssertNotNil(ClaudeUsageParser.tokens(
            inLine: line(requestID: "req-1"), cutoffISO: cutoff, seen: &seen
        ))
        XCTAssertNil(ClaudeUsageParser.tokens(
            inLine: line(requestID: "req-1"), cutoffISO: cutoff, seen: &seen
        ))
    }

    func testWpisSprzedPolnocyNieLiczySie() {
        var seen: Set<String> = []

        XCTAssertNil(ClaudeUsageParser.tokens(
            inLine: line(requestID: "req-old", timestamp: "2026-08-01T10:00:00.000Z"),
            cutoffISO: "2026-08-14T00:00:00",
            seen: &seen
        ))
    }

    func testSmieciNieWywracajaLicznika() {
        var seen: Set<String> = []

        XCTAssertNil(ClaudeUsageParser.tokens(
            inLine: Data("{obcięta linia".utf8), cutoffISO: "x", seen: &seen
        ))
        XCTAssertNil(ClaudeUsageParser.tokens(
            inLine: Data("{\"type\":\"user\"}".utf8), cutoffISO: "x", seen: &seen
        ))
    }

    // MARK: - Czytnik na prawdziwych plikach

    private func makeClaudeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/projekt"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func todayISO() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.000'Z'"
        return formatter.string(from: Date())
    }

    func testCzytnikSumujeDzisiejszeTranskrypty() throws {
        let root = try makeClaudeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("projects/projekt/a.jsonl")
        var body = Data()
        body.append(line(requestID: "req-1", timestamp: todayISO()))
        body.append(Data("\n".utf8))
        body.append(line(requestID: "req-1", timestamp: todayISO()))
        body.append(Data("\n".utf8))
        try body.write(to: transcript)

        let reader = ClaudeUsageReader(claudeDirectory: root)
        let counted = reader.tokensToday()

        XCTAssertEqual(counted.input, 1110, "powtórzony requestId nie liczy się drugi raz")
        XCTAssertEqual(counted.output, 50)
    }

    func testDopisaneLinieDochodzaPrzyrostowo() throws {
        let root = try makeClaudeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("projects/projekt/a.jsonl")
        var body = Data()
        body.append(line(requestID: "req-1", timestamp: todayISO()))
        body.append(Data("\n".utf8))
        try body.write(to: transcript)
        let reader = ClaudeUsageReader(claudeDirectory: root)
        XCTAssertEqual(reader.tokensToday().output, 50)

        var appended = Data()
        appended.append(line(requestID: "req-2", timestamp: todayISO(), output: 7))
        appended.append(Data("\n".utf8))
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        XCTAssertEqual(reader.tokensToday().output, 57)
    }

    func testPustoOznaczaBrakRaportuANieZera() throws {
        let root = try makeClaudeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(ClaudeUsageReader(claudeDirectory: root).report())
    }

    func testRaportBezSnapshotuMaKreskiZamiastZmyslonychProcentow() throws {
        let root = try makeClaudeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var body = Data()
        body.append(line(requestID: "req-1", timestamp: todayISO()))
        body.append(Data("\n".utf8))
        try body.write(to: root.appendingPathComponent("projects/projekt/a.jsonl"))

        let report = try XCTUnwrap(ClaudeUsageReader(claudeDirectory: root).report())

        XCTAssertNil(report.fiveHour, "brak snapshotu to niewiadoma, nie 0%")
        XCTAssertEqual(report.tokensIn, 1110)
        XCTAssertTrue(report.payload["fiveHour"] is NSNull)
    }

    func testPayloadNiesieWylacznieLiczby() throws {
        let report = ClaudeUsageReport(
            fiveHour: 58, sevenDay: 5, resetsAt: 1783881000, tokensIn: 1110, tokensOut: 50
        )

        XCTAssertEqual(
            Set(report.payload.keys),
            ["fiveHour", "sevenDay", "resetsAt", "tokensIn", "tokensOut"]
        )
        let encoded = String(
            data: try JSONSerialization.data(withJSONObject: report.payload),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(encoded.contains("tajny-klient"), "ścieżki projektów nie wychodzą")
    }
}
