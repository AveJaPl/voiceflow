import AppKit

/// Nazwy terminali dla trybu nasłuchu: „terminal pierwszy", „terminal drugi",
/// a jak chcesz — własna nazwa per okno.
///
/// Numery okien (`CGWindowID`) zmieniają się przy każdym restarcie Terminala,
/// więc NIE nadają się na klucz trwałej nazwy. Kluczem jest tytuł okna —
/// jedyna rzecz, którą użytkownik widzi i która przeżywa restart aplikacji.
/// Okna bez tytułu (macOS oddaje je dopiero po zgodzie „Nagrywanie ekranu")
/// dostają nazwy porządkowe, liczone od lewej-górnej strony ekranu, żeby
/// „pierwszy" znaczyło zawsze to samo okno w tym samym układzie.
@MainActor
struct TerminalRegistry {

    struct Terminal: Identifiable, Equatable {
        let id: String          // CGWindowID jako string (ważny w tej generacji)
        let pid: pid_t
        let title: String
        /// Nazwa, którą wołasz głosem.
        let name: String
        let ordinal: Int        // 1, 2, 3…
    }

    /// NAZWY KODOWE zamiast liczebników — najważniejsza zmiana po drugiej
    /// opinii (Codex, 2026-08-12) i po pomiarach na żywo.
    ///
    /// „pierwszy/drugi/trzeci" to dla polskiego ASR w hałasie najgorszy możliwy
    /// wybór: liczebniki porządkowe mylą się ze sobą i z głównymi („pierwszy" →
    /// „jeden"), a whisper regularnie oddawał je jako coś zupełnie innego.
    /// Poniższe słowa dobrane są tak, żeby (a) różniły się od siebie sylabicznie
    /// i samogłoskowo, (b) prawie nie padały w rozmowie o pracy — czyli żeby
    /// pomyłka „lampa"/„zebra" była praktycznie niemożliwa, a przypadkowe
    /// wyzwolenie w trakcie gadania mało prawdopodobne.
    static let ordinalNames = [
        "lampa", "zebra", "kokos", "radio", "mewa",
        "hotel", "wagon", "sosna", "migdał", "turban",
    ]

    private static let customNamesKey = "voiceflow.terminalNames"

    /// Własne nazwy: tytuł okna → nazwa głosowa.
    static func customNames(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: customNamesKey) as? [String: String] ?? [:]
    }

    static func setCustomName(_ name: String?, forTitle title: String, defaults: UserDefaults = .standard) {
        var names = customNames(defaults)
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            names[title] = name.trimmingCharacters(in: .whitespaces)
        } else {
            names.removeValue(forKey: title)
        }
        defaults.set(names, forKey: customNamesKey)
    }

    /// Terminale z migawki okien, w stabilnej kolejności (lewo-góra → prawo-dół),
    /// z nazwami do wołania głosem.
    static func terminals(from snapshot: WindowsFrame, snapshotter: WindowSnapshotter, defaults: UserDefaults = .standard) -> [Terminal] {
        let names = customNames(defaults)
        let sorted = snapshot.windows
            .filter(\.isTerminal)
            // Kolejność po pozycji, NIE po kolejności nakładania: układ okien
            // na biurku jest stały, a to, które jest na wierzchu, zmienia się
            // przy każdym kliknięciu — „pierwszy" nie może skakać.
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        return sorted.enumerated().map { index, window in
            let title = window.title ?? ""
            let ordinal = index + 1
            let fallback = ordinal <= ordinalNames.count ? ordinalNames[ordinal - 1] : "\(ordinal)"
            return Terminal(
                id: window.id,
                pid: snapshotter.pid(forWindowID: window.id) ?? 0,
                title: title.isEmpty ? "Terminal \(ordinal)" : title,
                name: names[title] ?? fallback,
                ordinal: ordinal
            )
        }
    }
}
