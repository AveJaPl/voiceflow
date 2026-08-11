import CoreAudio
import Foundation
import os.log

/// Przycisza/odcisza głośność systemową WYJŚCIA (całe audio, nie per-aplikacja —
/// macOS nie ma odpowiednika PipeWire dla tego bez sterownika audio, patrz
/// `reference/voiceflow/src/voiceflow/micmute.py` dla wersji Linux/PipeWire).
protocol AudioDucking {
    /// Zapamiętuje BIEŻĄCĄ głośność i przycisza ją do `duckVolume` (ułamek
    /// oryginału). Idempotentne: jeśli już przyciszone, nic nie robi — nie
    /// nadpisuje zapamiętanej oryginalnej głośności drugim wywołaniem.
    func start()
    /// Przywraca DOKŁADNIE głośność zapamiętaną przez ostatnie `start()`.
    /// No-op, jeśli nie było aktywnego przyciszenia.
    func stop()
}

/// CoreAudio: `kAudioHardwarePropertyDefaultOutputDevice` +
/// `kAudioDevicePropertyVolumeScalar`. Framework linkowalny bez dodatkowych
/// uprawnień/TCC — to nie jest ingerencja w cudzy proces, tylko wołanie HAL
/// na urządzeniu wyjścia.
final class AudioDucker: AudioDucking {
    // TODO(SettingsView): SettingsView jeszcze nie jest wpięte do aplikacji w
    // tej gałęzi (patrz progress.md 2026-08-09) — do czasu wpięcia to jedyna
    // droga konfiguracji: `defaults write io.github.avejapl.voiceflow voiceflow.audioDuckingEnabled -bool false`
    // / `defaults write io.github.avejapl.voiceflow voiceflow.duckVolume -float 0.2`.
    private static let enabledKey = "voiceflow.audioDuckingEnabled"
    private static let duckVolumeKey = "voiceflow.duckVolume"
    private static let defaultDuckVolume: Float32 = 0.2

    /// Stan jednego przyciszenia: albo głośność master, albo per-kanał (część
    /// urządzeń USB/Bluetooth nie wspiera master scalar, tylko kanały osobno —
    /// stąd oba warianty, nie zakładamy że jeden zawsze zadziała).
    private enum Restore {
        case master(Float32)
        case channels([UInt32: Float32])
    }

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "AudioDucker")
    private var active: (deviceID: AudioDeviceID, restore: Restore)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
    }

    private var duckVolume: Float32 {
        let stored = defaults.object(forKey: Self.duckVolumeKey) as? Double
        guard let stored, stored > 0, stored < 1 else { return Self.defaultDuckVolume }
        return Float32(stored)
    }

    func start() {
        guard isEnabled else { return }
        guard active == nil else { return } // już przyciszone — nie nadpisuj oryginału

        guard let deviceID = Self.defaultOutputDevice() else {
            log.error("Nie udało się odczytać domyślnego urządzenia wyjścia")
            return
        }

        if let original = Self.getVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain),
           Self.setVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain, volume: original * duckVolume) {
            active = (deviceID, .master(original))
            log.info("Duck: master \(original, privacy: .public) -> \(original * self.duckVolume, privacy: .public)")
            return
        }

        // Fallback: master scalar niedostępny/nieustawialny (typowe dla części
        // urządzeń USB/Bluetooth) — spróbuj kanałów osobno.
        var originals: [UInt32: Float32] = [:]
        for channel in Self.channelElements {
            guard let original = Self.getVolume(deviceID: deviceID, element: channel) else { continue }
            if Self.setVolume(deviceID: deviceID, element: channel, volume: original * duckVolume) {
                originals[channel] = original
            }
        }
        if !originals.isEmpty {
            active = (deviceID, .channels(originals))
            log.info("Duck: per-kanał \(originals.count, privacy: .public) kanały")
        } else {
            log.error("Urządzenie wyjścia nie wspiera VolumeScalar ani master, ani per-kanał — pomijam duck")
        }
    }

    func stop() {
        guard let active else { return }
        self.active = nil
        switch active.restore {
        case .master(let original):
            if !Self.setVolume(deviceID: active.deviceID, element: kAudioObjectPropertyElementMain, volume: original) {
                log.error("Nie udało się przywrócić głośności master \(original, privacy: .public)")
            } else {
                log.info("Duck: przywrócono master \(original, privacy: .public)")
            }
        case .channels(let originals):
            for (channel, original) in originals {
                if !Self.setVolume(deviceID: active.deviceID, element: channel, volume: original) {
                    log.error("Nie udało się przywrócić głośności kanału \(channel, privacy: .public)")
                }
            }
            log.info("Duck: przywrócono \(originals.count, privacy: .public) kanały")
        }
    }

    // MARK: - CoreAudio plumbing

    /// Kanały do wypróbowania, gdy master scalar nie działa — zwykły stereo
    /// wyjście ma 1 i 2, ale niektóre agregaty mają więcej; próbujemy szerzej
    /// zamiast cicho poddać się po dwóch kanałach.
    private static let channelElements: [UInt32] = Array(1...8)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return nil }
        return deviceID
    }

    private static func getVolume(deviceID: AudioDeviceID, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func setVolume(deviceID: AudioDeviceID, element: UInt32, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        var v = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &v) == noErr
    }
}
