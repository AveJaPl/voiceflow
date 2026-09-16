import AVFoundation
import Combine
import Foundation
import WhisperKit
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "DictationEngine")

/// Jeden silnik dyktowania dla całej apki (karta dyktowania, przepływ z
/// klawiatury, test w onboardingu). Pod spodem DWIE drogi:
///
/// - **whisper na urządzeniu** (WhisperKit, Core ML/Neural Engine) — domyślna,
///   gdy model jest pobrany i załadowany (`WhisperModelStore`). Nagrywamy całą
///   wypowiedź, po puszczeniu przycisku liczymy RAZ, z pełnym kontekstem —
///   tak samo jak przebieg końcowy na Macu. Bez podglądu na żywo: na telefonie
///   dekodowanie co pół sekundy kosztowałoby baterię, a tekst i tak trafia do
///   klawiatury dopiero po zakończeniu.
/// - **Apple `SFSpeechRecognizer`** (`ContainerDictationEngine`) — zapasowa,
///   dopóki model się pobiera albo gdy telefon go nie udźwignie. Daje podgląd
///   na żywo, ale po polsku myli się częściej.
///
/// Wybór jest automatyczny przy KAŻDYM starcie nagrania, więc pierwsze
/// dyktowania po instalacji idą przez Apple, a gdy tylko model dojedzie,
/// kolejne — przez whisper. Użytkownik nic nie przełącza.
@MainActor
final class DictationEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        /// Whisper liczy po zakończeniu nagrania — kilkaset ms do kilku sekund.
        case transcribing
        case error(String)
    }

    enum Backend: Equatable {
        case whisper(String)
        case apple

        var label: String {
            switch self {
            case .whisper(let title): "whisper \(title), na urządzeniu"
            case .apple: "Apple, na urządzeniu"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var liveText: String = ""
    /// RMS 0…1 z mikrofonu — do fali na karcie dyktowania.
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var backend: Backend = .apple

    private let apple = ContainerDictationEngine()
    private let models: WhisperModelStore
    private var appleObservers: Set<AnyCancellable> = []
    private var recordToHistory = true

    // Whisper: nagranie
    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var startedAt: Date?
    private var recordingPipeline: WhisperKit?
    private var recordingID = UUID()
    private var hasInputTap = false
    /// Jak na Macu: 5 minut maksimum, potem nagranie się ucina — bufor 64 KB/s.
    private static let maxSeconds = 300

    init(models: WhisperModelStore = .shared) {
        self.models = models
        apple.$state
            .sink { [weak self] appleState in
                guard let self, self.backend == .apple else { return }
                switch appleState {
                case .idle: self.state = .idle
                case .requestingPermission: self.state = .requestingPermission
                case .listening: self.state = .listening
                case .error(let message): self.state = .error(message)
                }
            }
            .store(in: &appleObservers)
        apple.$liveText
            .sink { [weak self] text in
                guard let self, self.backend == .apple else { return }
                self.liveText = text
            }
            .store(in: &appleObservers)
    }

    var isBusy: Bool { state == .listening || state == .requestingPermission || state == .transcribing }

    func toggle(recordToHistory: Bool = true) {
        switch state {
        case .listening:
            stop()
        case .transcribing, .requestingPermission:
            break
        default:
            self.recordToHistory = recordToHistory
            start()
        }
    }

    // MARK: - Start

    private func start() {
        if models.isReady, let pipeline = models.pipeline {
            backend = .whisper(models.selected.title)
            startWhisper(pipeline)
        } else {
            backend = .apple
            apple.toggle(recordToHistory: recordToHistory)
        }
    }

    private func startWhisper(_ pipeline: WhisperKit) {
        recordingPipeline = pipeline
        let id = UUID()
        recordingID = id
        liveText = ""
        state = .requestingPermission
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.recordingID == id, self.state == .requestingPermission else { return }
                guard granted else {
                    self.state = .error("Brak zgody na mikrofon — włącz ją w Ustawieniach.")
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .error("Nie udało się skonfigurować sesji audio: \(error.localizedDescription)")
            return
        }

        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 60)
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            releaseAudio()
            state = .error("Nie udało się przygotować konwersji audio.")
            return
        }
        self.converter = converter
        let target = targetFormat
        let id = recordingID
        input.removeTap(onBus: 0)
        // Tap woła z wątku audio: konwersja i RMS liczą się tam, stan
        // obserwowany przez UI zmienia się dopiero na głównym aktorze.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let mono = Self.resample(buffer, converter: converter, to: target)
            let level = Self.rms(mono)
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == id, self.state == .listening else { return }
                self.audioLevel = level
                let remaining = Self.maxSeconds * 16_000 - self.samples.count
                self.samples.append(contentsOf: mono.prefix(max(0, remaining)))
                if self.samples.count >= Self.maxSeconds * 16_000 { self.stop() }
            }
        }
        hasInputTap = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            releaseAudio()
            state = .error("Nie udało się uruchomić mikrofonu: \(error.localizedDescription)")
            return
        }
        startedAt = Date()
        state = .listening
    }

    /// Wołane z wątku audio — bez dotykania stanu obserwowanego przez UI.
    nonisolated private static func resample(
        _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, to targetFormat: AVAudioFormat
    ) -> [Float] {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    nonisolated private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples { sum += value * value }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - Stop

    private func releaseAudio() {
        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioLevel = 0
    }

    func cancel() {
        recordingID = UUID()
        apple.cancel()
        if backend != .apple { releaseAudio() }
        recordingPipeline = nil
        samples.removeAll()
        liveText = ""
        state = .idle
    }

    private func stop() {
        if backend == .apple {
            apple.toggle(recordToHistory: recordToHistory)
            return
        }
        guard state == .listening else { return }
        releaseAudio()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        guard let pipeline = recordingPipeline, samples.count > 1_600 else {
            recordingPipeline = nil
            samples.removeAll()
            state = .idle
            return
        }
        state = .transcribing
        let audio = samples
        samples.removeAll()
        recordingPipeline = nil
        let id = recordingID
        let vocabulary = UserDefaults.standard.stringArray(forKey: "voiceflow.customVocabulary") ?? []
        Task { [weak self] in
            do {
                let text = try await Self.transcribe(audio, with: pipeline, vocabulary: vocabulary)
                guard let self, self.recordingID == id else { return }
                guard !text.isEmpty else {
                    self.state = .error("Nie rozpoznano mowy. Spróbuj ponownie.")
                    return
                }
                self.finish(text: text, duration: duration)
            } catch {
                guard let self, self.recordingID == id else { return }
                self.state = .error("Nie udało się rozpoznać nagrania. Spróbuj ponownie.")
            }
        }
    }

    nonisolated private static func transcribe(_ audio: [Float], with pipeline: WhisperKit, vocabulary: [String]) async throws -> String {
        // Słownik jako prompt dekodera — ta sama sztuczka co
        // `WhisperSpeechEngine.buildInitialPrompt` na Macu.
        let promptTokens: [Int]? = vocabulary.isEmpty
            ? nil
            : pipeline.tokenizer?.encode(text: " " + vocabulary.joined(separator: ", "))
        let options = DecodingOptions(
            task: .transcribe,
            language: "pl",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens
        )
        do {
            let started = Date()
            let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "  ", with: " ")
            log.info("whisper: \(audio.count / 16_000) s audio → \(Date().timeIntervalSince(started), privacy: .public) s")
            return text
        } catch {
            log.error("whisper transcribe failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func finish(text: String, duration: TimeInterval) {
        liveText = text
        if recordToHistory, !text.isEmpty {
            DictationHistoryStore.append(DictationEntry(text: text, source: .containerApp))
            if let credentials = KeychainCredentialStore().load() {
                Task {
                    try? await AccountAPI.postHistory(
                        credentials: credentials, text: text,
                        createdAt: Date(), durationSeconds: duration, source: "phone"
                    )
                }
            }
        }
        state = .idle
    }
}
