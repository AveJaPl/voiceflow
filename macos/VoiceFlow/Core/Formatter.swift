import Foundation

/// Warstwa deterministyczna (§9 pkt 1, §5a): interpunkcja, wielkie litery,
/// wycinanie filerów, słownik nazw własnych. Po polsku to WYMÓG — `addsPunctuation`
/// nie działa dla pl (zmierzone), więc bez tego kroku tekst wygląda jak surowy
/// strumień słów bez kropki i przecinka.
///
/// LLM polish (§6a pkt 3) wchodzi później, asynchronicznie, na tym co ten
/// Formatter już wyprodukował — Formatter nie czeka na nic i działa w budżecie
/// volatile (0 ms, same tablice i reguły).
final class Formatter {
    /// Słownik własny: co ASR często myli → poprawna forma. Klucze porównywane
    /// bez rozróżniania wielkości liter, całe słowo.
    static let defaultDictionary: [String: String] = [
        // Projekty Wojtka
        "programo": "Programo",
        "estalo": "Estalo",
        "coolify": "Coolify",
        "jedmar": "Jedmar",
        "jest mera": "Jedmar",
        "contabo": "Contabo",
        "supabase": "Supabase",
        // Popularne narzędzia IT — Apple po polsku zwraca je poprawnie
        // ORTOGRAFICZNIE, ale małą literą jako zwykłe słowo w zdaniu; to tylko
        // POPRAWKA WIELKOŚCI LITER, nie próba zgadywania fonetycznych pomyłek
        // (tych nie da się przewidzieć bez realnych nagrań testowych).
        "discord": "Discord", "slack": "Slack", "notion": "Notion",
        "github": "GitHub", "gitlab": "GitLab", "docker": "Docker",
        "kubernetes": "Kubernetes", "figma": "Figma", "vercel": "Vercel",
        "linear": "Linear", "jira": "Jira", "airtable": "Airtable",
        "stripe": "Stripe", "zoom": "Zoom", "xcode": "Xcode",
        "swift": "Swift", "python": "Python", "typescript": "TypeScript",
        "javascript": "JavaScript", "next.js": "Next.js", "nextjs": "Next.js",
        "react": "React", "node": "Node", "postgres": "Postgres",
        "postgresql": "PostgreSQL", "mongodb": "MongoDB", "redis": "Redis",
        "neon": "Neon", "drizzle": "Drizzle", "cursor": "Cursor",
        "chatgpt": "ChatGPT", "claude": "Claude", "anthropic": "Anthropic",
        "openai": "OpenAI", "codex": "Codex", "whisper": "Whisper",
        "macos": "macOS", "ios": "iOS", "testflight": "TestFlight",
    ]

    /// Łączy `defaultDictionary` z wpisami użytkownika z Ustawień
    /// (`SettingsKeys.customVocabulary`, §Zadanie 1 audytu) — DRUGA warstwa
    /// korekty, niezależna od silnika ASR (dla whisper.cpp główną drogą jest
    /// `WhisperSpeechEngine.buildInitialPrompt`, ta funkcja działa też dla
    /// Apple-engine, gdzie nic takiego jak `initial_prompt` nie istnieje).
    /// Użytkownik NADPISUJE/DOKŁADA — każde jego słowo trafia jako klucz bez
    /// wielkości liter -> forma DOKŁADNIE tak jak ją zapisał, identycznie jak
    /// istniejące wpisy `defaultDictionary` (poprawka WIELKOŚCI LITER, nie
    /// zamiana treści). Wieloczłonowe frazy (np. "Wojciech Płonka") celowo
    /// pomijane tutaj — `applyDictionary` dopasowuje słowo po słowie, fraza
    /// wielowyrazowa nigdy nie trafi w pojedynczy klucz; dla fraz działa tylko
    /// druga ścieżka (prompt whisper.cpp).
    static func mergedDictionary(userVocabulary: [String], base: [String: String] = defaultDictionary) -> [String: String] {
        var merged = base
        for entry in userVocabulary {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains(" ") else { continue }
            merged[trimmed.lowercased()] = trimmed
        }
        return merged
    }

    /// Filery wielowyrazowe/leksykalne PL/EN — dokładne dopasowanie, bo to
    /// prawdziwe słowa/frazy, nie da się ich złapać wzorcem znakowym.
    static let defaultFillers: Set<String> = [
        "no więc", "znaczy", "że tak powiem", "like", "you know",
    ]

    /// Przeciągnięte wtrącenia ("mmm", "mmmm", "eee", "hmm", "ehm"...) — TA SAMA
    /// głoska powtórzona dowolną liczbę razy, zawsze wycinana bez względu na
    /// dokładną długość. Dokładne dopasowanie stringów ("mmm" != "mmmm" jako
    /// osobne słowa dla \b...\b) puszczało realnie zaobserwowane "Mmmm" —
    /// ASR nie trzyma się jednej długości wtrącenia między nagraniami.
    /// Znany kompromis: złapie też garstkę prawdziwych krótkich słów zbudowanych
    /// wyłącznie z tych liter (np. angielskie "hum", "yum") — rzadkie w realnym
    /// dyktowaniu, akceptowalne w zamian za złapanie WSZYSTKICH wariantów "mmm".
    private static let elongatedFillerPattern = "(?i)\\b[myehu]{2,}\\b"

    private let dictionary: [String: String]
    private let fillers: Set<String>

    init(dictionary: [String: String] = Formatter.defaultDictionary,
         fillers: Set<String> = Formatter.defaultFillers) {
        self.dictionary = dictionary
        self.fillers = fillers
    }

    /// Formatuje pojedynczy segment (między granicami VAD). `isSentenceStart`
    /// mówi, czy to początek nowej wypowiedzi (wielka litera + brak wiodącej spacji).
    func format(_ raw: String, isSentenceStart: Bool, endsUtterance: Bool) -> String {
        var text = removeFillers(raw)
        text = applyDictionary(text)
        text = collapseWhitespace(text)
        guard !text.isEmpty else { return text }

        if isSentenceStart {
            text = capitalizeFirstLetter(text)
        }
        if endsUtterance, !hasTerminalPunctuation(text) {
            // Wykrzyknik wymagałby intonacji (nacisk głosu), której nie mamy z
            // samego tekstu — zostaje poza zakresem. Pytajnik da się przybliżyć
            // heurystyką: polskie pytania w mowie prawie zawsze zaczynają się
            // od słowa pytającego ("czy", "co", "gdzie"...), więc to jest tani
            // i sensowny sygnał, mimo że nie łapie pytań bez takiego słowa
            // ("robisz to teraz?" zamiast "czy robisz to teraz?").
            text += looksLikeQuestion(text) ? "?" : "."
        }
        return text
    }

    // MARK: - Kroki

    private func removeFillers(_ text: String) -> String {
        // Przeciągnięte wtrącenia najpierw — jeden wzorzec łapie "mmm"/"mmmm"/"eee"
        // niezależnie od długości, zamiast osobnego wpisu na każdą wariację.
        var result = text.replacingOccurrences(
            of: Self.elongatedFillerPattern, with: "", options: .regularExpression
        )
        // Potem filery wielowyrazowe/leksykalne (dłuższe dopasowania mają pierwszeństwo).
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    private func applyDictionary(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (i, word) in words.enumerated() {
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            let lower = trimmed.lowercased()
            if let replacement = dictionary[lower], !trimmed.isEmpty {
                words[i] = word.replacingOccurrences(of: trimmed, with: replacement)
            }
        }
        return words.joined(separator: " ")
    }

    private func collapseWhitespace(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    private func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return ".!?…".contains(last)
    }

    private static let questionOpeners: Set<String> = [
        "czy", "co", "kto", "gdzie", "kiedy", "dlaczego", "jak", "ile",
        "jaki", "jaka", "jakie", "jacy", "który", "która", "które",
        "po co", "na co", "skąd", "czemu",
    ]

    private func looksLikeQuestion(_ text: String) -> Bool {
        let firstWord = text
            .split(separator: " ", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
        return Self.questionOpeners.contains(firstWord)
    }
}
