import AVFoundation
import os.log

/// `SpeechEngine` liczący na CUDZYM komputerze: własny serwer z `server/`,
/// drugi Mac udostępniający silnik w LAN, albo płatne API — wszystko przez
/// jeden kontrakt (`TranscriptionWire`). Bez podglądu na żywo: nagrywamy całą
/// wypowiedź, po puszczeniu skrótu jeden `POST`, tekst wraca w całości.
///
/// Fallback: gdy serwer nie odpowie (brak sieci, zły adres, 5xx), wypowiedź
/// NIE ginie — audio jest w buforze, więc liczymy je lokalnie modelem
/// whisper.cpp ładowanym leniwie. Użytkownik dostaje tekst o kilka sekund
/// później, a w logu widzi, dlaczego.
final class RemoteWhisperEngine: SpeechEngine {
    private let log = Logger(subsystem: "pl.programo.voiceflow", category: "RemoteWhisperEngine")
    private let queue = DispatchQueue(label: "pl.programo.voiceflow.remote-whisper", qos: .userInteractive)
    private let language: String
    private let defaults: UserDefaults

    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    let updates: AsyncStream<TranscriptUpdate>

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var isFeeding = false
    private var samples: [Float] = []
    private var generation = 0
    private static let maxSeconds = 300

    /// Lokalna deska ratunku — ładowana dopiero przy pierwszej awarii serwera.
    private var fallbackContext: WhisperContext?

    init(language: String = "pl", defaults: UserDefaults = .standard) {
        self.language = language
        self.defaults = defaults
        var cont: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    // MARK: - SpeechEngine

    func prewarm() async throws {
        // Nic do rozgrzania — sprawdzamy tylko, czy adres w ogóle się parsuje,
        // żeby błąd konfiguracji wyszedł przy starcie, nie przy pierwszym skrócie.
        guard TranscriptionWire.endpoint(from: defaults.string(forKey: SettingsKeys.transcriptionServerURL) ?? "") != nil else {
            throw NSError(domain: "RemoteWhisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Brak lub nieprawidłowy adres serwera transkrypcji (Ustawienia → Zaawansowane)."])
        }
    }

    func beginUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            samples.removeAll(keepingCapacity: true)
            generation &+= 1
            isFeeding = true
        }
    }

    func endUtterance() async -> String? {
        let (audio, myGeneration): ([Float], Int) = queue.sync {
            isFeeding = false
            return (samples, generation)
        }
        guard audio.count > 1_600 else { return nil }
        let vocabulary = defaults.stringArray(forKey: SettingsKeys.customVocabulary) ?? []
        let prompt = vocabulary.isEmpty ? "" : vocabulary.joined(separator: ", ")
        let started = Date()
        do {
            let text = try await Self.transcribeRemotely(audio, language: language, prompt: prompt, defaults: defaults)
            DebugLog.write("RemoteWhisper", String(format: "serwer: %.2f s audio → %.2f s", Double(audio.count) / 16_000, Date().timeIntervalSince(started)))
            guard queue.sync(execute: { generation == myGeneration }) else { return nil }
            return text.isEmpty ? nil : text
        } catch {
            DebugLog.write("RemoteWhisper", "serwer nie odpowiedział (\(error.localizedDescription)) — liczę lokalnie")
            let text = await transcribeLocally(audio, prompt: prompt)
            guard queue.sync(execute: { generation == myGeneration }) else { return nil }
            return text.isEmpty ? nil : text
        }
    }

    func cancelUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            isFeeding = false
            samples.removeAll(keepingCapacity: true)
            generation &+= 1
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, isFeeding, let mono = resample(buffer) else { return }
            if samples.count < Self.maxSeconds * 16_000 { samples.append(contentsOf: mono) }
        }
    }

    // MARK: - Serwer

    static func transcribeRemotely(_ audio: [Float], language: String, prompt: String, defaults: UserDefaults) async throws -> String {
        guard let url = TranscriptionWire.endpoint(from: defaults.string(forKey: SettingsKeys.transcriptionServerURL) ?? "") else {
            throw NSError(domain: "RemoteWhisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "nieprawidłowy adres serwera"])
        }
        let boundary = "voiceflow-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = KeychainPairingTokenStore.transcriptionServerKey.loadToken(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = TranscriptionWire.multipartBody(
            boundary: boundary, wav: TranscriptionWire.wavData(samples: audio), language: language, prompt: prompt
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "RemoteWhisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        guard let text = TranscriptionWire.text(fromResponse: data) else {
            throw NSError(domain: "RemoteWhisper", code: 3, userInfo: [NSLocalizedDescriptionKey: "odpowiedź bez pola text"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lokalny fallback

    private func transcribeLocally(_ audio: [Float], prompt: String) async -> String {
        let context: WhisperContext
        if let existing = queue.sync(execute: { fallbackContext }) {
            context = existing
        } else {
            do {
                let choice = WhisperModelChoice.current(defaults)
                let url = try await WhisperModelProvisioner.ensureModelAvailable(choice)
                let loaded = try await Task.detached(priority: .userInitiated) { try WhisperContext.load(modelPath: url.path) }.value
                queue.sync { fallbackContext = loaded }
                context = loaded
            } catch {
                DebugLog.write("RemoteWhisper", "lokalny fallback niedostępny: \(error.localizedDescription)")
                return ""
            }
        }
        let vad = await WhisperModelProvisioner.ensureVADModelAvailable()?.path
        let language = self.language
        return await Task.detached(priority: .userInitiated) {
            context.transcribeFull(
                samples: audio, language: language,
                initialPrompt: prompt.isEmpty ? "" : "Słownictwo: \(prompt).",
                beamSize: 1, vadModelPath: vad
            )
        }.value
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
