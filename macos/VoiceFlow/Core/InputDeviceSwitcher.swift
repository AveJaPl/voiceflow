import CoreAudio
import Foundation
import os.log

/// Izoluje mikrofon dla Discorda (i innych apek czatu) BEZ symulowania ich
/// przycisków i BEZ automatyzacji ich UI — czysto przez CoreAudio, tym samym
/// mechanizmem co `AudioDucker`.
///
/// Zasada: Discord (jak większość apek) nasłuchuje SYSTEMOWEGO DOMYŚLNEGO
/// wejścia audio (`kAudioHardwarePropertyDefaultInputDevice`), o ile jego
/// własne ustawienie mikrofonu w Discordzie stoi na "Domyślne" (nie na
/// nazwaną kartę na sztywno — WARUNEK KONIECZNY, do sprawdzenia ręcznie raz
/// przez Wojtka w Discord → Ustawienia → Głos i wideo → Urządzenie wejściowe).
///
/// Na czas dyktowania podmieniamy TEN systemowy domyślny wskaźnik na
/// "BlackHole 2ch" (cichy, wirtualny wkład audio — nic tam nie gra, więc
/// Discord słyszy ciszę), a WŁASNE nagrywanie (`AudioCapture`) jest PRZYPIĘTE
/// na sztywno do prawdziwego mikrofonu (patrz `AudioCapture.pin(to:)`) —
/// niezależnie od tego, co aktualnie jest "domyślne" w systemie. Po
/// dyktowaniu przywracamy DOKŁADNIE poprzedni domyślny wskaźnik.
final class InputDeviceSwitcher: AudioDucking {
    static let blackHoleDeviceName = "BlackHole 2ch"

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "InputDeviceSwitcher")
    private var originalDeviceID: AudioDeviceID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Wołane RAZ przy starcie aplikacji. Jeśli poprzednia sesja padła/zawisła
    /// z podmienionym wejściem (realnie zdarzyło się 2026-08-09 — mikrofon
    /// systemowy został na BlackHole i wymagał ręcznej naprawy skryptem POZA
    /// aplikacją), przywracamy prawdziwy mikrofon. Bez tego "nikt mnie nie
    /// słyszy" przeżywa restart aplikacji i wygląda jak zepsuty system.
    func recoverIfStuck() {
        guard let current = Self.defaultInputDevice() else { return }
        guard Self.deviceName(of: current) == Self.blackHoleDeviceName else { return }

        guard let realMic = Self.firstRealInputDevice() else {
            DebugLog.write("MicIsolation", "recover: wejście utknęło na BlackHole, ale NIE znalazłem prawdziwego mikrofonu")
            return
        }
        if Self.setDefaultInputDevice(realMic) {
            let name = Self.deviceName(of: realMic) ?? "?"
            DebugLog.write("MicIsolation", "recover: wejście utknęło na BlackHole -> przywrócono \(name) (\(realMic))")
        }
    }

    /// Pierwsze urządzenie WEJŚCIOWE, które nie jest BlackHole — preferuje
    /// wbudowany mikrofon (nazwa zawiera "MacBook"), żeby nie wylądować
    /// przypadkiem na mikrofonie iPhone'a przez Continuity.
    private static func firstRealInputDevice() -> AudioDeviceID? {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }

        let inputs = ids.filter { hasInputChannels($0) && deviceName(of: $0) != blackHoleDeviceName }
        return inputs.first { deviceName(of: $0)?.contains("MacBook") == true } ?? inputs.first
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else { return false }
        let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private var isEnabled: Bool {
        defaults.object(forKey: SettingsKeys.micIsolationEnabled) == nil
            ? false // domyślnie WYŁĄCZONE — wymaga BlackHole zainstalowanego i Discorda ustawionego na "Domyślne"; nie zgadujemy, że to gotowe
            : defaults.bool(forKey: SettingsKeys.micIsolationEnabled)
    }

    func start() {
        guard isEnabled else {
            DebugLog.write("MicIsolation", "start: pominięty — wyłączone w Ustawieniach")
            return
        }
        guard originalDeviceID == nil else { return } // już przełączone — nie nadpisuj oryginału
        guard let blackHole = Self.findDevice(named: Self.blackHoleDeviceName) else {
            DebugLog.write("MicIsolation", "start: BlackHole nie znalezione — czy zainstalowane?")
            return
        }
        guard let current = Self.defaultInputDevice() else {
            DebugLog.write("MicIsolation", "start: nie udało się odczytać bieżącego domyślnego wejścia")
            return
        }
        guard Self.setDefaultInputDevice(blackHole) else {
            DebugLog.write("MicIsolation", "start: nie udało się ustawić BlackHole jako domyślnego")
            return
        }
        originalDeviceID = current
        DebugLog.write("MicIsolation", "start: domyślne wejście \(current) -> BlackHole \(blackHole)")
    }

    func stop() {
        guard let original = originalDeviceID else { return }
        originalDeviceID = nil
        if Self.setDefaultInputDevice(original) {
            DebugLog.write("MicIsolation", "stop: przywrócono domyślne wejście \(original)")
        } else {
            log.error("Nie udało się przywrócić oryginalnego domyślnego wejścia \(original)")
            DebugLog.write("MicIsolation", "stop: FAILED przywrócenie \(original)")
        }
    }

    // MARK: - CoreAudio plumbing

    static func findDevice(named targetName: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return nil
        }
        for id in deviceIDs {
            if deviceName(of: id) == targetName {
                return id
            }
        }
        return nil
    }

    private static func deviceName(of deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (name as String) : nil
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    @discardableResult
    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id) == noErr
    }
}
