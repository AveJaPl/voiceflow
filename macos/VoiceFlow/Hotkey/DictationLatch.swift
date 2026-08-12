import Foundation

/// Tryb bez trzymania: podwójne stuknięcie klawisza dyktowania ZOSTAWIA sesję
/// otwartą (mów bez trzymania), a kolejne pojedyncze stuknięcie ją kończy.
/// Zwykłe przytrzymanie działa jak zawsze — wciskasz, mówisz, puszczasz.
///
/// Czysta maszyna stanów między `HotkeyMonitor` (surowe wciśnięcia/puszczenia)
/// a `SessionController` (begin/end) — bez zegara systemowego w środku, czas
/// przychodzi z zewnątrz, więc całość testuje się bez klawiatury i bez czekania.
///
/// Sekwencja zdarzeń przy podwójnym stuknięciu (dwa szybkie tapy):
///   tap 1: press → `begin`, release → `end`     (krótka pusta sesja — tak samo
///                                                działał szybki tap do tej pory)
///   tap 2: press → `begin`, release → `none`    (zatrzask: sesja zostaje otwarta)
///   tap 3: press → `end`,   release → `none`    (koniec dyktowania)
///
/// Zatrzask celowo NIE opóźnia `begin` do rozstrzygnięcia „tap czy podwójny tap"
/// — hold-to-talk musi startować natychmiast, a nie po oknie podwójnego
/// stuknięcia. Kosztem jest pusta sesja po tapie 1, którą `SessionController`
/// i tak wycisza (pusty tekst = zero wstrzykiwania).
final class DictationLatch {

    enum Action {
        /// Zacznij dyktowanie.
        case begin
        /// Zakończ dyktowanie (pełny przebieg + wstrzyknięcie).
        case end
        /// Nic nie rób — zatrzask trzyma sesję otwartą.
        case none
    }

    /// Dłuższe przyciśnięcie niż to nie jest już „stuknięciem" — to zwykłe
    /// hold-to-talk.
    private let quickTapMaxSeconds: TimeInterval
    /// Maksymalny odstęp między PUSZCZENIAMI dwóch szybkich stuknięć, żeby
    /// liczyły się jako podwójne.
    private let doubleTapWindowSeconds: TimeInterval

    private(set) var isLatched = false
    private var pressedAt: TimeInterval?
    private var lastQuickTapReleaseAt: TimeInterval = -.infinity
    /// Puszczenie klawisza po stuknięciu, które ZAMKNĘŁO zatrzask, nie może
    /// wygenerować drugiego `end`.
    private var suppressNextRelease = false

    init(quickTapMaxSeconds: TimeInterval = 0.35, doubleTapWindowSeconds: TimeInterval = 0.6) {
        self.quickTapMaxSeconds = quickTapMaxSeconds
        self.doubleTapWindowSeconds = doubleTapWindowSeconds
    }

    func pressed(at now: TimeInterval) -> Action {
        if isLatched {
            isLatched = false
            suppressNextRelease = true
            lastQuickTapReleaseAt = -.infinity
            return .end
        }
        pressedAt = now
        return .begin
    }

    func released(at now: TimeInterval) -> Action {
        if suppressNextRelease {
            suppressNextRelease = false
            return .none
        }
        let duration = now - (pressedAt ?? now)
        if duration <= quickTapMaxSeconds {
            if now - lastQuickTapReleaseAt <= doubleTapWindowSeconds {
                isLatched = true
                lastQuickTapReleaseAt = -.infinity
                return .none
            }
            lastQuickTapReleaseAt = now
        } else {
            // Realne przytrzymanie zeruje pamięć o pojedynczym stuknięciu —
            // tap, długi hold i tap zaraz po nim to nie jest „podwójny tap".
            lastQuickTapReleaseAt = -.infinity
        }
        return .end
    }

    /// Escape/anulowanie z zewnątrz: sesja już nie żyje, zatrzask nie ma czego
    /// trzymać.
    func reset() {
        isLatched = false
        suppressNextRelease = false
        pressedAt = nil
        lastQuickTapReleaseAt = -.infinity
    }
}
