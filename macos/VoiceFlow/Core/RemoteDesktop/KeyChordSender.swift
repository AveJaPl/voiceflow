import CoreGraphics

/// Wysyła skrót z zamkniętego słownika kontraktu (`KeyChord`) do aplikacji na
/// froncie. Celowo NIE ma tu ogólnego „naciśnij dowolny klawisz" — zdalne
/// wciskanie czegokolwiek na cudzym Macu to nie jest funkcja, której ktokolwiek
/// tu potrzebuje (plan §4.6); słownik zamknięty = powierzchnia ataku zamknięta.
enum KeyChordSender {

    /// Mapowanie na wirtualne kody klawiszy (Carbon `kVK_*`).
    static func mapping(for chord: KeyChord) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        switch chord {
        case .return_: (36, [])
        case .escape: (53, [])
        case .cmdReturn: (36, .maskCommand)
        case .ctrlC: (8, .maskControl) // 8 = klawisz „C"
        case .cmdZ: (6, .maskCommand)  // 6 = „Z"
        case .cmdV: (9, .maskCommand)  // 9 = „V"
        case .ctrlU: (32, .maskControl) // 32 = „U" — wyczyszczenie linii w powłoce
        default: nil
        }
    }

    /// `false` = akord spoza słownika (nowszy telefon) — wołający zgłasza
    /// `unsupported` zamiast udawać, że coś nacisnął.
    @discardableResult
    static func post(_ chord: KeyChord) -> Bool {
        guard let (keyCode, flags) = mapping(for: chord) else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
