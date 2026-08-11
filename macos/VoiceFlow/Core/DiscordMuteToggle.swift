import AppKit
import CoreGraphics
import os.log

/// Wycisza mikrofon Discorda na czas dyktowania przez symulację JEGO WŁASNEGO
/// globalnego skrótu "Wycisz" (Discord → Ustawienia → Skróty klawiszowe →
/// "Wycisz"/"Toggle Mute"). macOS nie ma jak wyciszyć cudzy strumień mikrofonu
/// bez sterownika audio (patrz `AudioDucker` i `micmute.py` referencyjny) —
/// to jedyna realna droga bez instalowania czegokolwiek.
protocol DiscordMuteToggling {
    /// Wysyła skonfigurowany skrót RAZ, jeśli jest skonfigurowany i Discord
    /// działa. No-op i cicho wyłączone, jeśli skrót nie jest ustawiony —
    /// NIE zgadujemy kombinacji.
    func start()
    /// Wysyła TĘ SAMĄ kombinację jeszcze raz (Discord ma jeden toggle, nie
    /// osobne mute/unmute) — tylko jeśli `start()` faktycznie coś wysłał.
    func stop()
}

/// OGRANICZENIE ZNANE I ŚWIADOME (nie do naprawienia bez prywatnego API/sterownika):
/// jeśli użytkownik wyciszył się w Discordzie RĘCZNIE przed dyktowaniem, `stop()`
/// i tak wyśle toggle i go ODCISZY. PipeWire w oryginalnym `micmute.py` wie, czy
/// strumień był już wyciszony (`_is_muted()`), bo czyta stan przez `wpctl`; przez
/// CGEvent nie mamy jak odczytać stanu przycisku w cudzej aplikacji.
final class DiscordMuteToggle: DiscordMuteToggling {
    private static let discordBundleID = "com.hnc.Discord"
    // TODO(SettingsView): SettingsView jeszcze nie jest wpięte do aplikacji w
    // tej gałęzi (patrz progress.md 2026-08-09) — do czasu wpięcia konfiguracja
    // wyłącznie przez `defaults write io.github.avejapl.voiceflow <klucz> -int <wartość>`.
    private static let keyCodeKey = "voiceflow.discordMuteHotkeyKeyCode"
    private static let modifierFlagsKey = "voiceflow.discordMuteHotkeyModifierFlags"

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "DiscordMuteToggle")
    private var pendingUntoggle = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        guard !pendingUntoggle else {
            DebugLog.write("Discord", "start: pominięty — już wysłane w tej sesji")
            return
        }
        guard let combo = configuredCombo() else {
            DebugLog.write("Discord", "start: pominięty — brak skonfigurowanego skrótu")
            return
        }
        guard isDiscordRunning() else {
            DebugLog.write("Discord", "start: pominięty — Discord nie działa")
            return
        }
        do {
            try CGEventKeyCombo.post(keyCode: combo.keyCode, flags: combo.flags, holdMillis: 20)
            pendingUntoggle = true
            log.info("Discord mute toggle wysłany (start dyktowania)")
            DebugLog.write("Discord", "start: wysłano keyCode=\(combo.keyCode) flags=\(combo.flags.rawValue)")
        } catch {
            log.error("Discord mute toggle (start) nie powiódł się: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("Discord", "start: FAILED \(error)")
        }
    }

    func stop() {
        guard pendingUntoggle else {
            DebugLog.write("Discord", "stop: pominięty — nic nie było wysłane")
            return
        }
        pendingUntoggle = false
        guard let combo = configuredCombo() else {
            DebugLog.write("Discord", "stop: pominięty — brak skonfigurowanego skrótu")
            return
        }
        do {
            try CGEventKeyCombo.post(keyCode: combo.keyCode, flags: combo.flags, holdMillis: 20)
            log.info("Discord mute toggle wysłany (koniec dyktowania)")
            DebugLog.write("Discord", "stop: wysłano keyCode=\(combo.keyCode) flags=\(combo.flags.rawValue)")
        } catch {
            log.error("Discord mute toggle (koniec) nie powiódł się: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("Discord", "stop: FAILED \(error)")
        }
    }

    private func isDiscordRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.discordBundleID }
    }

    private func configuredCombo() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard defaults.object(forKey: Self.keyCodeKey) != nil else { return nil }
        let keyCode = defaults.integer(forKey: Self.keyCodeKey)
        guard keyCode >= 0 else { return nil }
        let rawFlags = defaults.object(forKey: Self.modifierFlagsKey) != nil
            ? UInt64(defaults.integer(forKey: Self.modifierFlagsKey))
            : 0
        return (CGKeyCode(keyCode), CGEventFlags(rawValue: rawFlags))
    }
}
