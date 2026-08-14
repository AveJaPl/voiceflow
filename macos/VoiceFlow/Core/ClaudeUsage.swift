import Foundation

/// Zużycie Claude Code na tej maszynie: procenty limitów ze snapshotu paska
/// statusu (`~/.claude/statusline-last.json`) i tokeny zsumowane z dzisiejszych
/// transkryptów sesji (`~/.claude/projects/**/*.jsonl`).
///
/// Odpowiednik `src/voiceflow/claudeusage.py`, celowo reguła w regułę: ten sam
/// próg świeżości, ta sama deduplikacja i ta sama zasada prywatności — pliki
/// zawierają całe rozmowy, a stąd wychodzą wyłącznie liczby. Nigdy nazwa
/// sesji, katalog roboczy ani treść.
///
/// Dwa zmierzone fakty kształtują implementację (patrz testy strony
/// pythonowej): jedna odpowiedź API leży w transkrypcie w KILKU liniach z tym
/// samym `requestId` i identycznym `usage` — liczenie linii potraja wynik —
/// oraz jeden dzień transkryptów potrafi ważyć setki megabajtów, więc pliki
/// czyta się przyrostowo, od zapamiętanego miejsca. Stan zeruje się o lokalnej
/// północy.

struct ClaudeUsageReport: Equatable {
    /// Procenty limitów; nil = ta maszyna nie zna swoich limitów (brak
    /// snapshotu paska statusu). Na tablicy nil to kreska, nie zmyślone 0%.
    var fiveHour: Int?
    var sevenDay: Int?
    var resetsAt: Int
    var tokensIn: Int
    var tokensOut: Int

    /// Kształt 1:1 z klientem pythonowym — serwer i tablica znają jeden format.
    var payload: [String: Any] {
        [
            "fiveHour": fiveHour.map { $0 as Any } ?? NSNull(),
            "sevenDay": sevenDay.map { $0 as Any } ?? NSNull(),
            "resetsAt": resetsAt,
            "tokensIn": tokensIn,
            "tokensOut": tokensOut,
        ]
    }
}

/// Czyste reguły parsowania — testowalne bez plików i bez Claude Code.
enum ClaudeUsageParser {

    /// Po tylu sekundach snapshot przestaje mówić cokolwiek o „teraz".
    static let staleAfterSeconds: TimeInterval = 6 * 3600

    /// Procenty obu okien ze snapshotu paska statusu, albo nil dla wszystkiego
    /// nieużywalnego — brakującej sekcji, nieświeżego pliku, kształtu
    /// zmienionego w aktualizacji Claude Code.
    static func percentages(
        statusline document: [String: Any],
        ageSeconds: TimeInterval
    ) -> (fiveHour: Int, sevenDay: Int, resetsAt: Int)? {
        guard ageSeconds <= staleAfterSeconds,
              let limits = document["rate_limits"] as? [String: Any]
        else { return nil }
        let five = limits["five_hour"] as? [String: Any] ?? [:]
        let seven = limits["seven_day"] as? [String: Any] ?? [:]
        let fiveHour = clampedPercentage(five["used_percentage"])
        let sevenDay = clampedPercentage(seven["used_percentage"])
        if fiveHour == nil && sevenDay == nil { return nil }
        let resets = (five["resets_at"] as? NSNumber)?.intValue ?? 0
        return (fiveHour ?? 0, sevenDay ?? 0, resets)
    }

    /// Tokeny z jednej linii transkryptu, albo nil dla linii bez użycia,
    /// wpisu sprzed dzisiejszej północy i powtórzonej odpowiedzi (requestId
    /// widziany wcześniej). Znaczniki czasu w transkryptach to UTC ISO —
    /// takie napisy sortują się jak czas, więc „od północy" to zwykłe
    /// porównanie ze stałym progiem.
    static func tokens(
        inLine line: Data,
        cutoffISO: String,
        seen: inout Set<String>
    ) -> (input: Int, output: Int)? {
        guard
            let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let timestamp = entry["timestamp"] as? String, timestamp >= cutoffISO,
            let message = entry["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return nil }
        if let requestID = entry["requestId"] as? String {
            if seen.contains(requestID) { return nil }
            seen.insert(requestID)
        }
        func count(_ key: String) -> Int {
            guard let number = usage[key] as? NSNumber else { return 0 }
            return max(0, number.intValue)
        }
        let input = count("input_tokens")
            + count("cache_creation_input_tokens")
            + count("cache_read_input_tokens")
        return (input, count("output_tokens"))
    }

    private static func clampedPercentage(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return max(0, min(100, Int(number.doubleValue.rounded())))
    }
}

/// Czyta pliki i trzyma stan przyrostowy: offsety, widziane odpowiedzi, sumy.
/// Nie jest bezpieczny wątkowo — `ClaudeUsageReporter` woła go zawsze z jednej
/// kolejki i tak ma zostać.
final class ClaudeUsageReader {

    private let claudeDirectory: URL
    private var day: String?
    private var offsets: [URL: UInt64] = [:]
    private var seen: Set<String> = []
    private var tokensIn = 0
    private var tokensOut = 0

    /// Format dnia w strefie lokalnej — klucz zerowania o północy.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Lokalna północ wyrażona jako napis UTC — do porównań ze znacznikami
    /// czasu w transkryptach.
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    init(claudeDirectory: URL? = nil) {
        self.claudeDirectory = claudeDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
    }

    /// Pełny raport do pokoju, albo nil gdy nie ma zupełnie nic do pokazania.
    /// Nieświeży pasek statusu przy świeżych transkryptach (i odwrotnie) daje
    /// raport częściowy — pół obrazu jest lepsze niż brak kafelka.
    func report(now: Date = Date()) -> ClaudeUsageReport? {
        let (input, output) = tokensToday(now: now)
        let limits = statuslinePercentages(now: now)
        if limits == nil && input == 0 && output == 0 { return nil }
        return ClaudeUsageReport(
            fiveHour: limits?.fiveHour,
            sevenDay: limits?.sevenDay,
            resetsAt: limits?.resetsAt ?? 0,
            tokensIn: input,
            tokensOut: output
        )
    }

    /// (wejście z cache, wyjście) od lokalnej północy.
    func tokensToday(now: Date = Date()) -> (input: Int, output: Int) {
        let midnight = Calendar.current.startOfDay(for: now)
        let today = Self.dayFormatter.string(from: midnight)
        if today != day {
            day = today
            offsets.removeAll()
            seen.removeAll()
            tokensIn = 0
            tokensOut = 0
        }
        let cutoffISO = Self.utcFormatter.string(from: midnight)
        let projects = claudeDirectory.appendingPathComponent("projects")
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "jsonl",
                  let values = try? item.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize
            else { continue }
            var offset = offsets[item.standardizedFileURL] ?? 0
            if modified < midnight && offset == 0 {
                // Nietknięty od północy: w środku nie ma nic z dzisiaj.
                continue
            }
            if UInt64(size) < offset {
                // Skrócony albo przepisany; czytamy od nowa — zbiór widzianych
                // requestId chroni już policzone odpowiedzi przed podwojeniem.
                offset = 0
            }
            if UInt64(size) == offset { continue }
            offsets[item.standardizedFileURL] = consume(item, from: offset, cutoffISO: cutoffISO)
        }
        return (tokensIn, tokensOut)
    }

    /// Zlicza kompletne nowe linie; zwraca offset, do którego doczytano.
    private func consume(_ file: URL, from offset: UInt64, cutoffISO: String) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return offset }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.readToEnd(), !chunk.isEmpty
        else { return offset }
        // Ktoś może właśnie dopisywać: kompletne jest tylko to, co kończy się
        // znakiem nowej linii.
        var complete = chunk
        if complete.last != UInt8(ascii: "\n") {
            guard let lastNewline = complete.lastIndex(of: UInt8(ascii: "\n")) else {
                return offset
            }
            complete = Data(complete.prefix(through: lastNewline))
        }
        let marker = Data("\"usage\"".utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil else { continue }
            if let counted = ClaudeUsageParser.tokens(
                inLine: Data(line), cutoffISO: cutoffISO, seen: &seen
            ) {
                tokensIn += counted.input
                tokensOut += counted.output
            }
        }
        return offset + UInt64(complete.count)
    }

    private func statuslinePercentages(
        now: Date
    ) -> (fiveHour: Int, sevenDay: Int, resetsAt: Int)? {
        let file = claudeDirectory.appendingPathComponent("statusline-last.json")
        guard
            let data = try? Data(contentsOf: file),
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
            let modified = values.contentModificationDate,
            let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return ClaudeUsageParser.percentages(
            statusline: document,
            ageSeconds: max(0, now.timeIntervalSince(modified))
        )
    }
}

/// Cykliczny nadawca: co minutę czyta liczby na własnej kolejce (pierwszy skan
/// dnia potrafi zająć chwilę i nie ma prawa zamrozić UI) i oddaje gotowy
/// payload przez callback.
final class ClaudeUsageReporter: @unchecked Sendable {

    private static let intervalSeconds: TimeInterval = 60

    private let queue = DispatchQueue(
        label: "io.github.avejapl.voiceflow.claudeusage", qos: .utility
    )
    private let reader: ClaudeUsageReader
    private let deliver: ([String: Any]?) -> Void
    private var timer: DispatchSourceTimer?

    init(
        reader: ClaudeUsageReader = ClaudeUsageReader(),
        deliver: @escaping ([String: Any]?) -> Void
    ) {
        self.reader = reader
        self.deliver = deliver
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + 1,
                repeating: Self.intervalSeconds
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.deliver(self.reader.report()?.payload)
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
}
