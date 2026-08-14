import XCTest
@testable import VoiceFlow

/// Licznik zużycia Claude Code. Dwa zmierzone fakty z transkryptów decydują
/// o poprawności wyniku i oba mają tu test: jedna odpowiedź API bywa zapisana
/// w kilku linijkach z tym samym `requestId` (liczenie linii zawyżyłoby wynik
/// kilkukrotnie), a w plikach leżą też wpisy z poprzednich dni.
final class ClaudeUsageTests: XCTestCase {

    private func makeTranscripts(_ lines: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vf-usage-\(UUID().uuidString)/projekt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sesja.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return root.deletingLastPathComponent()
    }

    private func entry(requestID: String, timestamp: String, input: Int, output: Int, cacheRead: Int = 0) -> String {
        """
        {"requestId":"\(requestID)","timestamp":"\(timestamp)","message":{"usage":{"input_tokens":\(input),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    func testProcentyZPaskaStatusu() throws {
        let json = Data("""
        {"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1755172800},
        "seven_day":{"used_percentage":7.9}}}
        """.utf8)
        let limits = try XCTUnwrap(ClaudeUsageCounter.parseLimits(json))
        XCTAssertEqual(limits.fiveHour, 42)
        XCTAssertEqual(limits.sevenDay, 8)
        XCTAssertEqual(limits.resetsAt, 1_755_172_800)
    }

    /// Kształt pliku zmieniony przez aktualizację Claude Code = brak kafelka,
    /// nie zmyślone zero.
    func testNieznanyKsztaltPlikuToBrakDanych() {
        XCTAssertNil(ClaudeUsageCounter.parseLimits(Data("{\"cokolwiek\":1}".utf8)))
        XCTAssertNil(ClaudeUsageCounter.parseLimits(Data("nie json".utf8)))
    }

    func testJednaOdpowiedzWKilkuLinijkachLiczySieRaz() async throws {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: "Z", with: "")
        let root = try makeTranscripts([
            entry(requestID: "req-1", timestamp: stamp, input: 100, output: 20, cacheRead: 5),
            entry(requestID: "req-1", timestamp: stamp, input: 100, output: 20, cacheRead: 5),
            entry(requestID: "req-2", timestamp: stamp, input: 10, output: 2),
        ])
        let counter = ClaudeUsageCounter(
            statuslineURL: root.appendingPathComponent("nie-ma.json"),
            projectsURL: root
        )
        let tokens = await counter.tokensToday(now: now)
        XCTAssertEqual(tokens.input, 115)
        XCTAssertEqual(tokens.output, 22)
    }

    func testWpisyZPoprzednichDniNieSaLiczone() async throws {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: "Z", with: "")
        let root = try makeTranscripts([
            entry(requestID: "wczoraj", timestamp: "2020-01-01T10:00:00", input: 999, output: 999),
            entry(requestID: "dzis", timestamp: stamp, input: 7, output: 3),
        ])
        let counter = ClaudeUsageCounter(
            statuslineURL: root.appendingPathComponent("nie-ma.json"),
            projectsURL: root
        )
        let tokens = await counter.tokensToday(now: now)
        XCTAssertEqual(tokens.input, 7)
        XCTAssertEqual(tokens.output, 3)
    }

    /// Brak paska statusu (typowo na macOS) to `nil` w procentach, nigdy 0 —
    /// zero byłoby liczbą, której nikt nie zmierzył.
    func testBrakPaskaStatusuToNilWProcentach() async throws {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: "Z", with: "")
        let root = try makeTranscripts([entry(requestID: "a", timestamp: stamp, input: 5, output: 1)])
        let counter = ClaudeUsageCounter(
            statuslineURL: root.appendingPathComponent("nie-ma.json"),
            projectsURL: root
        )
        let computed = await counter.currentPayload(now: now)
        let payload = try XCTUnwrap(computed)
        XCTAssertNil(payload.fiveHour)
        XCTAssertNil(payload.sevenDay)
        XCTAssertEqual(payload.tokensIn, 5)
    }
}
