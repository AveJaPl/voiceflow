import Foundation

/// Abstrakcja nad `DispatchWorkItem` — żeby testy mogły podstawić fejka i
/// sprawdzić, czy odroczone przywrócenie zostało anulowane, bez czekania na
/// prawdziwy zegar.
protocol CancellableSchedule {
    func cancel()
}
extension DispatchWorkItem: CancellableSchedule {}

/// Koordynuje WŁĄCZANIE `AudioDucking`/`DiscordMuteToggling` na PIERWSZE wejście
/// w sesję dyktowania i ich WYŁĄCZANIE dopiero jeśli w ciągu `gapThreshold` nie
/// przyjdzie kolejne `begin()` — czyli dopiero gdy dyktowanie NAPRAWDĘ się
/// skończyło, a nie przy każdej krótkiej przerwie w tej samej myśli (inaczej
/// głośność systemowa migałaby między kolejnymi wypowiedziami).
///
/// Wydzielone z `SessionController` wyłącznie po to, żeby dało się przetestować
/// tę logikę na atrapach protokołów, bez prawdziwego CoreAudio/CGEvent/Dispatch —
/// patrz `VoiceFlowTests/DictationDuckingTests.swift`.
final class DictationDucking {
    private let ducker: AudioDucking
    private let discordMute: DiscordMuteToggling
    /// Izolacja mikrofonu przez podmianę systemowego domyślnego wejścia na
    /// BlackHole (§Core/InputDeviceSwitcher) — ta sama `AudioDucking` semantyka
    /// (idempotentny start, dokładne przywrócenie), inny mechanizm niż `ducker`
    /// (ten przycisza WYJŚCIE/odtwarzanie, nie WEJŚCIE/mikrofon).
    private let micIsolator: AudioDucking
    /// Discord Rich Presence (§Zadanie 3 audytu) — TA SAMA semantyka
    /// "pierwsze wejście startuje, dopiero prawdziwy koniec zatrzymuje" jak
    /// `ducker`/`discordMute`/`micIsolator`, więc status w Discordzie nie
    /// miga między krótkimi przerwami w tej samej myśli.
    private let presence: DiscordPresenceReporting
    private let gapThreshold: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> CancellableSchedule

    private var pendingRestore: CancellableSchedule?

    init(
        ducker: AudioDucking,
        discordMute: DiscordMuteToggling,
        micIsolator: AudioDucking = InputDeviceSwitcher(),
        presence: DiscordPresenceReporting = DiscordPresence(),
        gapThreshold: TimeInterval = 1.5,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> CancellableSchedule = DictationDucking.mainQueueSchedule
    ) {
        self.ducker = ducker
        self.discordMute = discordMute
        self.micIsolator = micIsolator
        self.presence = presence
        self.gapThreshold = gapThreshold
        self.schedule = schedule
    }

    /// Wołane z `SessionController.beginUtterance()`.
    func begin() {
        if let pending = pendingRestore {
            // Kolejne wciśnięcie skrótu przyszło zanim minął próg — kontynuacja
            // tej samej myśli. Anuluj odroczone przywrócenie, zostaw aktywne.
            pending.cancel()
            pendingRestore = nil
        } else {
            ducker.start()
            discordMute.start()
            micIsolator.start()
            presence.start()
        }
    }

    /// Wołane z `SessionController.endUtterance()` (i `cancelUtterance()`).
    func end() {
        pendingRestore = schedule(gapThreshold) { [weak self] in
            self?.ducker.stop()
            self?.discordMute.stop()
            self?.micIsolator.stop()
            self?.presence.stop()
            self?.pendingRestore = nil
        }
    }

    private static func mainQueueSchedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> CancellableSchedule {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}
