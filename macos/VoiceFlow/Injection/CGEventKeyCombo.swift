import CoreGraphics

/// Prymitywna, reużywalna wysyłka jednej kombinacji klawiszy przez CGEvent
/// (keyDown+keyUp z modyfikatorami). Wydzielone z `TextInjector` (⌘V), bo
/// `DiscordMuteToggle` potrzebuje dokładnie tego samego mechanizmu do wysłania
/// dowolnego skonfigurowanego skrótu, nie tylko wklejania.
enum CGEventKeyCombo {
    enum Error: Swift.Error {
        case creationFailed
    }

    /// `holdMillis`: opóźnienie między keyDown a keyUp. Domyślnie 0 (wklejanie
    /// przez ⌘V już działa niezawodnie z zerem — nie ryzykujemy tego zmianą).
    /// Discord wysyła > 0, bo zdarzenie keyDown+keyUp z zerowym odstępem jest
    /// "zbyt idealne" względem prawdziwego naciśnięcia i część aplikacji
    /// (obserwowane: Discord czasem gubi drugie z dwóch identycznych toggle)
    /// może je inaczej traktować niż realny, mierzalny nacisk klawisza.
    static func post(keyCode: CGKeyCode, flags: CGEventFlags, holdMillis: UInt32 = 0) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { throw Error.creationFailed }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        if holdMillis > 0 {
            usleep(holdMillis * 1000)
        }
        up.post(tap: .cghidEventTap)
    }
}
