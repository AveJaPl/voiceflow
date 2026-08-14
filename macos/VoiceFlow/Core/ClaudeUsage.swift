import Foundation

/// Ile Claude Code spalił dziś na TEJ maszynie — kafelek na tablicy pokoju.
///
/// Parytet z wersją linuksową (`src/voiceflow/claudeusage.py`). Ten sam kształt
/// ładunku i te same zasady, bo obie aplikacje meldują się do tego samego
/// pokoju i muszą się dogadać co do liczb.
///
/// CO STĄD WYCHODZI: cztery liczby. Nigdy nazwa sesji, katalog roboczy, koszt
/// w dolarach ani nic, z czego dałoby się wyczytać, nad czym ktoś siedział.
/// Transkrypty zawierają całe rozmowy, więc ta klasa ma jeden obowiązek
/// nadrzędny: wyjąć z linijki cztery liczby i nie wypuścić niczego więcej.
///
/// DWA ZMIERZONE FAKTY z transkryptów, które wymusiły kształt implementacji
/// (obserwacja Filipa, potwierdzona tutaj na moim katalogu):
///   • jedna odpowiedź API bywa zapisana jako KILKA linii z tym samym
///     `requestId` i identycznym `usage` — liczenie linii zawyżałoby wynik
///     kilkukrotnie, więc odpowiedzi są odsiewane po identyfikatorze;
///   • jeden dzień transkryptów to setki megabajtów, więc pliki czytamy
///     przyrostowo: tylko bajty dopisane od poprzedniego zajrzenia.
/// Wszystko zeruje się o lokalnej północy.
/// AKTOR, nie klasa na głównym wątku. Zmierzone w testach 2026-08-14: jeden
/// przebieg liczenia to przejście po ~60 katalogach projektów i setkach
/// megabajtów transkryptów — na głównym wątku zawiesiłby interfejs (i zawiesił
/// test zdalnego mikrofonu, który przestał dostawać ramki). Kafelek nie ma
/// prawa zatrzymać dyktowania ani rysowania okna.
actor ClaudeUsageCounter {

    struct Payload: Equatable {
        /// Procent zużycia okna 5-godzinnego; `nil` = ta maszyna nie zna
        /// swoich limitów. NIGDY 0 zamiast `nil` — zero byłoby zmyśleniem.
        let fiveHour: Int?
        let sevenDay: Int?
        /// Kiedy odnawia się okno 5-godzinne (sekundy epoki), 0 = nieznane.
        let resetsAt: Int
        let tokensIn: Int
        let tokensOut: Int

        var asDictionary: [String: Any] {
            var payload: [String: Any] = [
                "resetsAt": resetsAt,
                "tokensIn": tokensIn,
                "tokensOut": tokensOut,
            ]
            payload["fiveHour"] = fiveHour as Any? ?? NSNull()
            payload["sevenDay"] = sevenDay as Any? ?? NSNull()
            return payload
        }
    }

    /// Po tylu godzinach snapshot paska statusu przestaje mówić cokolwiek
    /// o „teraz". Pokazanie go dalej byłoby podaniem starej liczby jako bieżącej.
    static let staleAfter: TimeInterval = 6 * 3600
    /// Jak często przeliczamy tokeny. Częściej nie ma sensu: liczby i tak
    /// zmieniają się skokowo, a to jest czytanie z dysku.
    static let refreshInterval: TimeInterval = 60

    private let statuslineURL: URL
    private let projectsURL: URL

    private var day: String?
    private var offsets: [String: UInt64] = [:]
    private var seenRequestIDs: Set<String> = []
    private var tokensIn = 0
    private var tokensOut = 0
    private var countedAt: Date?

    init(
        statuslineURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/statusline-last.json"),
        projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    ) {
        self.statuslineURL = statuslineURL
        self.projectsURL = projectsURL
    }

    /// Pełny ładunek do pokoju, albo `nil` gdy nie ma czym się dzielić.
    /// Nieświeży pasek statusu przy świeżych transkryptach (albo odwrotnie)
    /// daje ładunek CZĘŚCIOWY, bo pół obrazka jest lepsze niż brak kafelka.
    func currentPayload(now: Date = Date()) -> Payload? {
        let limits = readStatusline(now: now)
        let (input, output) = tokensToday(now: now)
        guard limits != nil || input > 0 || output > 0 else { return nil }
        return Payload(
            fiveHour: limits?.fiveHour,
            sevenDay: limits?.sevenDay,
            resetsAt: limits?.resetsAt ?? 0,
            tokensIn: input,
            tokensOut: output
        )
    }

    // MARK: - Pasek statusu (procenty limitów)

    struct Limits: Equatable {
        let fiveHour: Int?
        let sevenDay: Int?
        let resetsAt: Int
    }

    /// Claude Code na macOS zwykle NIE zapisuje `statusline-last.json` — wtedy
    /// procenty lecą jako `nil`, a kafelek pokazuje same tokeny.
    private func readStatusline(now: Date) -> Limits? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: statuslineURL.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= Self.staleAfter,
              let data = try? Data(contentsOf: statuslineURL) else { return nil }
        return Self.parseLimits(data)
    }

    static func parseLimits(_ data: Data) -> Limits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let five = limits["five_hour"] as? [String: Any] ?? [:]
        let seven = limits["seven_day"] as? [String: Any] ?? [:]
        let fiveHour = percentage(five["used_percentage"])
        let sevenDay = percentage(seven["used_percentage"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return Limits(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            resetsAt: (five["resets_at"] as? NSNumber).map { Int(truncating: $0) } ?? 0
        )
    }

    private static func percentage(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return max(0, min(100, Int(number.doubleValue.rounded())))
    }

    // MARK: - Tokeny z transkryptów

    /// (wejściowe razem z cache, wyjściowe) od lokalnej północy.
    func tokensToday(now: Date = Date()) -> (input: Int, output: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        if today != day {
            day = today
            offsets.removeAll()
            seenRequestIDs.removeAll()
            tokensIn = 0
            tokensOut = 0
            countedAt = nil
        }
        if let countedAt, now.timeIntervalSince(countedAt) < Self.refreshInterval {
            return (tokensIn, tokensOut)
        }

        let midnight = Calendar.current.startOfDay(for: now)
        // Znaczniki czasu w transkryptach to ISO w UTC, a takie napisy sortują
        // się jak czas — „od północy" to zwykłe porównanie tekstu.
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        isoFormatter.timeZone = TimeZone(identifier: "UTC")
        let cutoff = isoFormatter.string(from: midnight)

        for url in transcriptFiles() {
            let key = url.path
            let offset = offsets[key] ?? 0
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: key),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            // Nietknięty od północy i nigdy nieczytany — nie ma w nim dzisiaj.
            if modified < midnight, offset == 0 { continue }
            // Plik skrócony albo przepisany — czytamy od zera; zbiór widzianych
            // identyfikatorów pilnuje, żeby nic nie policzyło się dwa razy.
            let start = size < offset ? 0 : offset
            if size == start { continue }
            offsets[key] = read(url, from: start, cutoff: cutoff)
        }
        countedAt = now
        return (tokensIn, tokensOut)
    }

    private func transcriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// Liczy tylko PEŁNE linie i oddaje offset, do którego doczytał — pisarz
    /// może być w połowie linii, a policzenie jej połowy to błąd parsowania
    /// i zgubiona odpowiedź.
    private func read(_ url: URL, from offset: UInt64, cutoff: String) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return offset }

        let newline = UInt8(ascii: "\n")
        let complete: Data
        if chunk.last == newline {
            complete = chunk
        } else if let lastNewline = chunk.lastIndex(of: newline) {
            complete = chunk[chunk.startIndex...lastNewline]
        } else {
            return offset
        }

        for line in complete.split(separator: newline) where !line.isEmpty {
            count(line: Data(line), cutoff: cutoff)
        }
        return offset + UInt64(complete.count)
    }

    private func count(line: Data, cutoff: String) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestamp = entry["timestamp"] as? String, timestamp >= cutoff,
              let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        if let requestID = (entry["requestId"] as? String) ?? (usage["request_id"] as? String) {
            guard !seenRequestIDs.contains(requestID) else { return }
            seenRequestIDs.insert(requestID)
        }

        func value(_ key: String) -> Int {
            guard let number = usage[key] as? NSNumber else { return 0 }
            let integer = Int(truncating: number)
            return integer > 0 ? integer : 0
        }

        tokensIn += value("input_tokens")
            + value("cache_creation_input_tokens")
            + value("cache_read_input_tokens")
        tokensOut += value("output_tokens")
    }
}
