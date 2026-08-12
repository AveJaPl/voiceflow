import Foundation

/// Liczby stojące za tablicą pokoju, trzymane osobno od widoków, które je rysują.
///
/// JEDEN plik źródłowy dla macOS i iOS (kompilowany przez oba `project.yml`) —
/// obie platformy patrzą na tę samą sesję, więc nie mogą pokazywać różnych
/// wyników. Nie kopiować do katalogu platformy: kopia rozjeżdża się po cichu.
///
/// Odpowiednik `app/voiceflow_app/roomdata.py` z Linuksa, wzór w wzór. Udział i
/// dystans do lidera liczymy TUTAJ, a nie w widoku, bo to są dwie liczby, które
/// robią z tablicy rywalizację — a błędna liczba wygląda dokładnie tak samo jak
/// prawdziwa.
struct BoardRow: Equatable, Identifiable {
    let position: Int
    let name: String
    let words: Int
    let seconds: Int
    let dictations: Int
    let averageWords: Int
    /// Udział w słowach całej sesji, 0–100.
    let share: Int
    /// Ile słów brakuje do lidera; lider ma zero.
    let behind: Int

    var id: String { "\(position)-\(name)" }
}

enum RoomBoard {

    /// Zamienia ładunek rankingu na wiersze gotowe do narysowania.
    ///
    /// UWAGA na zaokrąglanie: Python zaokrągla „do parzystej" (`round(0.5) == 0`),
    /// a Swiftowe `rounded()` — „od zera" (`0.5 → 1`). Przy udziałach kończących
    /// się na .5 dałoby to inny procent niż na Linuksie i tej samej sesji, więc
    /// jawnie wymuszamy `.toNearestOrEven`.
    static func rows(from ranking: [[String: Any]]) -> [BoardRow] {
        let total = ranking.reduce(0) { $0 + intValue($1["words"]) }
        let leader = ranking.first.map { intValue($0["words"]) } ?? 0

        return ranking.enumerated().map { index, entry in
            let words = intValue(entry["words"])
            let share = total > 0
                ? Int((Double(words) * 100 / Double(total)).rounded(.toNearestOrEven))
                : 0
            return BoardRow(
                position: index + 1,
                name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—",
                words: words,
                seconds: intValue(entry["seconds"]),
                dictations: intValue(entry["dictations"]),
                averageWords: intValue(entry["averageWords"]),
                share: share,
                behind: max(0, leader - words)
            )
        }
    }

    /// Czas mówienia tak, jak pokazuje go tablica webowa — z dokładnością do minuty.
    static func formatDuration(seconds: Double) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.toNearestOrEven)))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0, rest > 0 { return "\(hours) godz. \(rest) min" }
        if hours > 0 { return "\(hours) godz." }
        return "\(minutes) min"
    }

    /// Jak długo trwa sesja, jako HH:MM:SS.
    ///
    /// Pauza („—") dla czegokolwiek nieparsowalnego: sesja, której startu nie
    /// umiemy odczytać, jest uczciwiej pokazana jako nieznana niż jako zero.
    static func sessionElapsed(startedAt: String, now: Date = Date()) -> String {
        guard let moment = parseTimestamp(startedAt) else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(moment)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, rest)
    }

    /// Serwer zwraca ISO 8601; z ułamkami sekund albo bez, zależnie od sterownika bazy.
    static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let int = raw as? Int { return int }
        if let double = raw as? Double { return Int(double) }
        if let string = raw as? String, let parsed = Int(string) { return parsed }
        return 0
    }
}

// MARK: - Sieć

/// Skład pokoju i bieżąca sesja — `GET /api/rooms/:kod/ranking`.
struct RoomSnapshot: Equatable {
    let sessionName: String?
    let sessionStartedAt: String?
    let rows: [BoardRow]

    static let empty = RoomSnapshot(sessionName: nil, sessionStartedAt: nil, rows: [])
}

enum RoomBoardClient {

    enum BoardError: LocalizedError {
        case badServer

        var errorDescription: String? { "Nie udało się odczytać tablicy pokoju." }
    }

    /// REST i WebSocket dzielą ten sam adres, więc `wss://` zamieniamy na
    /// `https://`. Kopia `RoomJoiner.httpBase` z macOS — świadoma, bo ten plik
    /// kompiluje się też na iOS, gdzie `RoomJoiner` (rejestracja urządzenia
    /// i dołączanie do pokoju) w ogóle nie istnieje.
    static func httpBase(_ server: String) throws -> String {
        var base = server.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst("wss://".count) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst("ws://".count) }
        guard base.hasPrefix("http://") || base.hasPrefix("https://"), URL(string: base) != nil else {
            throw BoardError.badServer
        }
        return base
    }

    static func fetchRanking(server: String, code: String) async throws -> RoomSnapshot {
        let base = try httpBase(server)
        guard let url = URL(string: "\(base)/api/rooms/\(code)/ranking") else {
            throw BoardError.badServer
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BoardError.badServer
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BoardError.badServer
        }
        let session = object["session"] as? [String: Any]
        let ranking = object["ranking"] as? [[String: Any]] ?? []
        // Usługa pokoi oddaje znacznik czasu jako `started_at` (tak wychodzi
        // z bazy), a nie `startedAt` — zweryfikowane na żywym serwerze
        // 2026-08-11. Drugi wariant zostawiony na wypadek, gdyby serwer kiedyś
        // przeszedł na camelCase: zegar sesji nie ma prawa stanąć przez to,
        // że ktoś przemianował jedno pole.
        let startedAt = (session?["started_at"] as? String) ?? (session?["startedAt"] as? String)
        return RoomSnapshot(
            sessionName: session?["name"] as? String,
            sessionStartedAt: startedAt,
            rows: RoomBoard.rows(from: ranking)
        )
    }

    /// Otwiera NOWĄ nazwaną sesję — `POST /api/rooms/:kod/session`.
    /// Serwer zamyka poprzednią w ramach tej samej operacji (dwie otwarte sesje
    /// rozjechałyby ranking), więc tu nie ma osobnego kroku zamykania.
    static func startSession(server: String, code: String, name: String?, token: String) async throws {
        let base = try httpBase(server)
        guard let url = URL(string: "\(base)/api/rooms/\(code)/session") else {
            throw BoardError.badServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name as Any])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BoardError.badServer
        }
    }

    static func endSession(server: String, code: String, token: String) async throws {
        let base = try httpBase(server)
        guard let url = URL(string: "\(base)/api/rooms/\(code)/session/end") else {
            throw BoardError.badServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BoardError.badServer
        }
    }
}
