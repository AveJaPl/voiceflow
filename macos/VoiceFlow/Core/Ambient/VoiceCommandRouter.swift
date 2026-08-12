import Foundation

/// Maszyna stanów trybu nasłuchu: „terminal pierwszy nasłuchuj" → mówisz prompt
/// → „koniec terminal pierwszy" → tekst ląduje w tamtym oknie.
///
/// CZYSTA logika — żadnego audio, whispera, okien ani zegara. Dostaje kolejne
/// fragmenty transkrypcji, oddaje decyzje. Dzięki temu cała gramatyka komend
/// (łącznie z tym, jak bardzo whisper potrafi przekręcić słowo) jest w całości
/// pokryta testami bez mikrofonu.
///
/// Dlaczego dopasowanie ROZMYTE, a nie porównanie tekstu: whisper nigdy nie
/// odda tego samego polecenia dwa razy identycznie — zmierzone na żywo w tej
/// aplikacji: „nasłuchuj" / „na słuchuj" / „nasłuchój" / „nas słuchaj".
/// Porównanie znak w znak dawałoby funkcję, która działa co drugi raz, a to
/// gorsze niż brak funkcji.
struct VoiceCommandRouter {

    enum Decision: Equatable {
        /// Nic ciekawego — fragment nie był komendą i nie zbieramy promptu.
        case ignore
        /// Zaczynamy zbierać prompt dla tego celu (nazwa znormalizowana).
        case startedCollecting(target: String)
        /// Fragment doszedł do zbieranego promptu; `text` to całość dotąd.
        case collecting(target: String, text: String)
        /// Koniec — wklej `text` do `target`.
        case commit(target: String, text: String)
        /// „anuluj" w trakcie zbierania — zapomnij, nic nie wklejaj.
        case cancelled(target: String)
    }

    /// Nazwy celów w kolejności zgłoszenia (np. ["pierwszy", "drugi", "claude"]).
    /// Dopasowanie idzie po tej liście, więc własne nazwy działają tak samo jak
    /// liczebniki.
    private let targets: [String]
    private var collectingTarget: String?
    private var collected: [String] = []

    init(targets: [String]) {
        self.targets = targets.map { Self.normalize($0) }.filter { !$0.isEmpty }
    }

    /// Słowa uruchamiające nasłuch dla celu — sprawdzane rozmycie, więc
    /// wystarczy jeden wzorzec na wariant znaczeniowy.
    /// RDZENIE, nie całe słowa: whisper rozbija i odmienia komendy w sposób,
    /// którego nie da się wyliczyć — zmierzone na żywo dla jednego zdania
    /// „terminal jeden nasłuchuj": „na słuchanie", „na słowę", „nasłuchuj",
    /// „na słuchaj". Wspólny jest tylko rdzeń „słuch". Szukamy go w całym
    /// znormalizowanym fragmencie, więc rozbicie na dwa słowa nic nie psuje.
    /// Fraza budząca: DWA rzadkie słowa. Jedno krótkie słowo („słuchaj")
    /// pada w normalnej rozmowie i dawało fałszywe wyzwolenia, a jego rdzeń
    /// whisper i tak przekręcał. „Halo" + nazwa kodowa okna to zestawienie,
    /// które w rozmowie o pracy nie występuje.
    static let startStems = ["halo", "sluch"]
    static let endStems = ["koniec", "wysl", "koncz"]
    static let cancelStems = ["anuluj", "odwolaj", "kasuj"]

    mutating func consume(_ fragment: String) -> Decision {
        let normalized = Self.normalize(fragment)
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return currentCollectingDecision() }

        // KONIEC ma pierwszeństwo przed STARTEM: „koniec terminal pierwszy"
        // zawiera nazwę celu, więc kolejność sprawdzania decyduje o tym, czy
        // wypowiedź kończy prompt, czy zaczyna nowy.
        if let target = collectingTarget {
            if Self.containsStem(normalized, anyOf: Self.cancelStems) {
                collectingTarget = nil
                collected.removeAll()
                return .cancelled(target: target)
            }
            if Self.containsStem(normalized, anyOf: Self.endStems) {
                let text = collected.joined(separator: " ")
                collectingTarget = nil
                collected.removeAll()
                // Pusty prompt („nasłuchuj" i od razu „koniec") nie ma czego
                // wklejać — traktujemy jak anulowanie, żeby nie wysyłać pustki.
                return text.isEmpty ? .cancelled(target: target) : .commit(target: target, text: text)
            }
            // Zwykła treść promptu — dokładamy fragment TAK, JAK PADŁ
            // (z interpunkcją i wielkością liter), nie znormalizowany, ale bez
            // powtórki: okna audio ZACHODZĄ na siebie o 1,5 s, więc początek
            // fragmentu bywa końcem poprzedniego.
            let fresh = Self.dropOverlap(of: fragment.trimmingCharacters(in: .whitespacesAndNewlines),
                                         after: collected.last ?? "")
            if !fresh.isEmpty { collected.append(fresh) }
            return .collecting(target: target, text: collected.joined(separator: " "))
        }

        if Self.containsStem(normalized, anyOf: Self.startStems), let target = matchTarget(in: words) {
            collectingTarget = target
            collected.removeAll()
            return .startedCollecting(target: target)
        }
        return .ignore
    }

    /// Czy zbieramy teraz prompt (do pokazania w pillu/UI).
    var activeTarget: String? { collectingTarget }

    /// Przeniesienie stanu zbierania do routera z odświeżoną listą celów —
    /// nazwy terminali zmieniają się w trakcie pracy, a prompt w połowie
    /// zdania nie może przez to przepaść.
    mutating func restore(from other: VoiceCommandRouter) {
        collectingTarget = other.collectingTarget
        collected = other.collected
    }

    mutating func reset() {
        collectingTarget = nil
        collected.removeAll()
    }

    private func currentCollectingDecision() -> Decision {
        guard let target = collectingTarget else { return .ignore }
        return .collecting(target: target, text: collected.joined(separator: " "))
    }

    /// Whisper po polsku myli liczebniki porządkowe z głównymi („terminal
    /// pierwszy" → „terminal jeden", zmierzone na żywo), więc każdy porządkowy
    /// ma alias liczbowy i cyfrę.
    /// Warianty, którymi whisper potrafi oddać nazwę kodową, plus stare
    /// liczebniki — kto przywykł do „terminal jeden", ma to dalej działać.
    static let ordinalAliases: [String: [String]] = [
        "lampa": ["lampe", "lampy", "jeden", "1", "pierwszy"],
        "zebra": ["zebre", "zebry", "dwa", "2", "drugi"],
        "kokos": ["kokosa", "kokosy", "trzy", "3", "trzeci"],
        "radio": ["radia", "radiu", "cztery", "4", "czwarty"],
        "mewa": ["mewe", "mewy", "piec", "5", "piaty"],
        "hotel": ["hotelu", "hotele", "szesc", "6", "szosty"],
        "wagon": ["wagonu", "wagony", "siedem", "7", "siodmy"],
        "sosna": ["sosne", "sosny", "osiem", "8", "osmy"],
        "migdal": ["migdaly", "migdala", "dziewiec", "9", "dziewiaty"],
        "turban": ["turbana", "turbany", "dziesiec", "10", "dziesiaty"],
    ]

    private func matchTarget(in words: [String]) -> String? {
        // Najpierw aliasy liczbowe — „jeden" nie może przegrać z rozmytym
        // dopasowaniem do innej nazwy.
        for target in targets {
            for alias in Self.ordinalAliases[target] ?? [] where words.contains(where: { Self.similar($0, alias) }) {
                return target
            }
        }
        for target in targets {
            let targetWords = target.split(separator: " ").map(String.init)
            // Cel wielowyrazowy („claude backend") musi wystąpić w całości.
            if targetWords.count > 1 {
                if Self.containsSequence(words, targetWords) { return target }
                continue
            }
            if words.contains(where: { Self.similar($0, target) }) { return target }
        }
        return nil
    }

    // MARK: - Dopasowanie rozmyte

    /// Bez znaków diakrytycznych, bez interpunkcji, małymi literami — whisper
    /// potrafi oddać „nasłuchuj" jako „nasluchuj" albo „Nasłuchuj,".
    static func normalize(_ text: String) -> String {
        // „ł" NIE jest literą z diakrytykiem w sensie Unicode (to osobny znak,
        // nie „l" + kreska), więc `folding` go nie rusza — zmierzone: „nasłuchuj"
        // przechodziło przez normalizację nietknięte i nie pasowało do
        // „nasluchuj" z innego przebiegu whispera. Zdejmujemy je ręcznie.
        let deStroked = text
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ł", with: "L")
        let folded = deStroked.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
        let cleaned = folded.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
        return String(cleaned).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Ucina z początku `fragment` słowa, które powtarzają koniec `previous`
    /// — skutek nakładania się okien audio.
    static func dropOverlap(of fragment: String, after previous: String) -> String {
        let previousWords = normalize(previous).split(separator: " ").map(String.init)
        let fragmentWords = fragment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let normalizedFragment = normalize(fragment).split(separator: " ").map(String.init)
        guard !previousWords.isEmpty, !normalizedFragment.isEmpty else { return fragment }
        let maxOverlap = min(previousWords.count, normalizedFragment.count)
        for n in stride(from: maxOverlap, through: 1, by: -1) {
            let tail = previousWords.suffix(n)
            let head = normalizedFragment.prefix(n)
            if zip(tail, head).allSatisfy({ similar($0, $1) }) {
                return fragmentWords.dropFirst(n).joined(separator: " ")
            }
        }
        return fragment
    }

    /// Rdzeń szukany w CAŁYM znormalizowanym tekście — łapie też komendę
    /// rozbitą przez whispera na dwa słowa („na słuchanie" → „na sluchanie").
    static func containsStem(_ normalizedText: String, anyOf stems: [String]) -> Bool {
        let compact = normalizedText.replacingOccurrences(of: " ", with: "")
        return stems.contains { normalizedText.contains($0) || compact.contains($0) }
    }

    static func contains(_ words: [String], anyOf patterns: [String]) -> Bool {
        let normalized = patterns.map { normalize($0) }
        return words.contains { word in normalized.contains { similar(word, $0) } }
    }

    private static func containsSequence(_ words: [String], _ sequence: [String]) -> Bool {
        guard sequence.count <= words.count else { return false }
        for start in 0...(words.count - sequence.count) {
            let slice = Array(words[start..<(start + sequence.count)])
            if zip(slice, sequence).allSatisfy({ similar($0, $1) }) { return true }
        }
        return false
    }

    /// Dwa słowa uznajemy za to samo, gdy różnią się najwyżej jedną operacją
    /// na cztery znaki długości (odległość Levenshteina). Próg dobrany tak,
    /// żeby „nasluchuj"/„nasluchoj" przeszły, a „pierwszy"/„czwarty" nie.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let allowed = max(1, min(a.count, b.count) / 4)
        guard abs(a.count - b.count) <= allowed else { return false }
        return levenshtein(Array(a), Array(b), limit: allowed) <= allowed
    }

    private static func levenshtein(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
                rowMinimum = min(rowMinimum, current[j])
            }
            // Cały wiersz powyżej progu — dalej może być tylko gorzej.
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
