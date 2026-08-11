import AVFoundation
import CoreAudio
import QuartzCore
import os.log

/// Przechwytywanie audio z mikrofonu, `.userInteractive` QoS na wątku dostawy
/// bufora — bez pośrednich kolejek między tapem a konsumentem (§5d, dźwignia 5).
final class AudioCapture {
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "AudioCapture")
    private let engine = AVAudioEngine()
    private let deliveryQueue = DispatchQueue(label: "io.github.avejapl.voiceflow.audio", qos: .userInteractive)
    /// Prawdziwy mikrofon, przypięty NA SZTYWNO — patrz `pinToCurrentDefaultInput()`.
    private var pinnedDeviceID: AudioDeviceID?

    /// Bufor w formacie natywnym wejścia (bez `AVAudioConverter` w gorącej ścieżce
    /// — konwersję do formatu silnika robi konsument, jeśli musi).
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// RMS 0...1 tej samej ramki — do waveformu w pillu i do `Segmenter`.
    var onLevel: ((Float, TimeInterval) -> Void)?

    private(set) var isRunning = false

    /// Format wejścia sprzętowego — publiczne, żeby `SpeechEngine` mógł zbudować
    /// żądanie rozpoznawania z dokładnie tym samym formatem.
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// SOLO DO TESTÓW (`WhisperSpeechEngineTests`): jeśli ustawione, `start()`/
    /// `stop()` wołają to zamiast dotykać `AVAudioEngine`/mikrofonu — pozwala
    /// przepuścić `SessionController.beginUtterance()`/`endUtterance()` przez
    /// realny cykl bez mikrofonu, karmiąc `onBuffer`/`onLevel` ręcznie z pliku
    /// WAV, DOKŁADNIE tym samym kanałem co prawdziwe nagrywanie —
    /// `SessionController` nie wie, że nie ma mikrofonu, więc nie wymaga
    /// żadnej zmiany (docs/plans/whisper-local-engine-pl.md, kryterium #4).
    /// `nil` (domyślnie) = identyczne zachowanie jak dziś.
    var startOverride: (() throws -> Void)?
    var stopOverride: (() -> Void)?

    /// Zapamiętuje BIEŻĄCE domyślne wejście jako "prawdziwy mikrofon" i
    /// przypina do niego silnik na sztywno (`kAudioOutputUnitProperty_
    /// CurrentDevice`), niezależnie od tego, co później stanie się domyślnym
    /// wejściem systemowym. WOŁAĆ WCZEŚNIE (przy starcie aplikacji, w
    /// `prewarm()`) — zanim `InputDeviceSwitcher` kiedykolwiek podmieni
    /// systemowy domyślny wskaźnik na BlackHole. Bez tego zamiana domyślnego
    /// wejścia na czas dyktowania ogłuszyłaby TAKŻE nasze własne nagrywanie.
    func pinToCurrentDefaultInput() {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            log.error("Nie udało się odczytać domyślnego wejścia do przypięcia")
            return
        }
        pinnedDeviceID = deviceID

        guard let audioUnit = engine.inputNode.audioUnit else {
            log.error("Brak audioUnit na inputNode — nie mogę przypiąć urządzenia")
            return
        }
        var pinned = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &pinned,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            log.info("Przypięto nagrywanie do urządzenia \(deviceID, privacy: .public)")
        } else {
            log.error("AudioUnitSetProperty (CurrentDevice) nie powiódł się: \(status, privacy: .public)")
        }
    }

    enum CaptureError: LocalizedError {
        case invalidInputFormat(sampleRate: Double, channels: UInt32)

        var errorDescription: String? {
            switch self {
            case let .invalidInputFormat(sampleRate, channels):
                "Urządzenie wejściowe zwróciło nieprawidłowy format (\(sampleRate) Hz, \(channels) kan.) — mikrofon mógł zostać zmieniony w trakcie."
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        if let startOverride {
            try startOverride()
            isRunning = true
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // `installTap` z nieprawidłowym formatem rzuca NSException, która NIE
        // JEST łapalna przez `catch` w Swifcie — wywala CAŁĄ aplikację
        // (SIGABRT, realny crash 2026-08-09 przy podmianie urządzenia
        // wejściowego w trakcie startu). Sprawdzamy format sami i zwracamy
        // normalny, obsługiwalny błąd Swift.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("Nieprawidłowy format wejścia: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) kan.")
            throw CaptureError.invalidInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.deliveryQueue.async {
                self.onBuffer?(buffer, time)
                let level = Self.rms(of: buffer)
                self.onLevel?(level, time.sampleTime > 0 ? Double(time.sampleTime) / format.sampleRate : CACurrentMediaTime())
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        log.info("AudioCapture started, format: \(format.sampleRate, privacy: .public) Hz")
    }

    func stop() {
        guard isRunning else { return }
        if let stopOverride {
            stopOverride()
            isRunning = false
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        log.info("AudioCapture stopped")
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameCount {
            let s = samples[i]
            sum += s * s
        }
        return sqrt(sum / Float(frameCount))
    }
}
