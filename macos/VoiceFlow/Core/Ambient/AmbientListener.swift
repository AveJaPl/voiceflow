import AVFoundation
import Foundation

/// Tryb nasłuchu: mikrofon chodzi ciągle, whisper tnie strumień ciszą i oddaje
/// fragmenty do `VoiceCommandRouter`. Mówisz „terminal pierwszy nasłuchuj",
/// dyktujesz prompt, mówisz „koniec" — tekst ląduje w tamtym oknie.
///
/// WŁASNY silnik i WŁASNE przechwytywanie audio, osobne od skrótu: skrót ma
/// dużą jakość (beam, duży model), nasłuch ma być tani i natychmiastowy
/// (greedy, `base`). Gdy startuje dyktowanie skrótem, nasłuch się WYCISZA —
/// dwa strumienie naraz to podwójny koszt i ryzyko, że komenda padnie w środku
/// promptu.
///
/// Cięcie ciszą, nie stałym oknem: komenda „koniec" musi zadziałać natychmiast
/// po jej wypowiedzeniu, a nie po upływie sztywnych sekund.
@MainActor
final class AmbientListener {

    /// Co robić z gotowym poleceniem (podnieś okno i wklej — patrz `VoiceFlowApp`).
    var onCommit: ((_ targetName: String, _ text: String) -> Void)?
    /// Zmiana stanu do pokazania w UI: nil = bezczynny, inaczej nazwa celu.
    var onStateChange: ((_ target: String?, _ text: String) -> Void)?
    /// Skąd wziąć aktualne nazwy terminali (odświeżane przy każdym starcie zbierania).
    var targetsProvider: (() -> [String])?

    private let capture = AudioCapture()
    private let queue = DispatchQueue(label: "pl.programo.voiceflow.ambient", qos: .userInitiated)
    private var context: WhisperContext?
    private var router = VoiceCommandRouter(targets: [])
    private(set) var isRunning = false
    /// Wstrzymanie na czas dyktowania skrótem — bez zrywania sesji audio.
    private var isMuted = false

    // Bufor bieżącego wypowiedzenia (16 kHz mono) i detektor ciszy.
    private var segment: [Float] = []
    private var silentSamples = 0
    private var hasSpeech = false

    /// Próg energii uznawany za mowę. Zmierzony na mikrofonie MacBooka: szum
    /// pokoju daje ~0,004 RMS, cicha mowa ~0,03.
    private static let speechThreshold: Float = 0.012
    /// Tyle ciszy kończy fragment (600 ms) — krócej cięłoby w środku zdania.
    private static let silenceSamplesToCut = 9_600
    /// Bezpiecznik: fragment dłuższy niż 20 s idzie do dekodera tak czy siak.
    private static let maxSegmentSamples = 20 * 16_000

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    func start() async {
        guard !isRunning else { return }
        do {
            // `base` — najtańszy model; nasłuch ma rozpoznać komendę i prompt,
            // a nie wygrać konkurs dokładności (tekst i tak można poprawić).
            let modelURL = try await WhisperModelProvisioner.ensureModelAvailable(.base)
            let loaded = try await Task.detached(priority: .utility) {
                try WhisperContext.load(modelPath: modelURL.path)
            }.value
            context = loaded
            capture.onBuffer = { [weak self] buffer, _ in
                self?.queue.async { self?.feed(buffer) }
            }
            try capture.start()
            isRunning = true
            DebugLog.write("Ambient", "tryb nasłuchu włączony")
        } catch {
            DebugLog.write("Ambient", "nie udało się włączyć nasłuchu: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        capture.onBuffer = nil
        context = nil
        isRunning = false
        resetSegment()
        router.reset()
        onStateChange?(nil, "")
        DebugLog.write("Ambient", "tryb nasłuchu wyłączony")
    }

    /// Dyktowanie skrótem przejmuje mikrofon — nasłuch milczy do jego końca.
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        if muted { resetSegment() }
        DebugLog.write("Ambient", muted ? "nasłuch wyciszony (dyktowanie skrótem)" : "nasłuch wznowiony")
    }

    // MARK: - Strumień audio (na `queue`)

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, !isMuted, let mono = resample(buffer) else { return }
        let energy = Self.rms(mono)
        if energy >= Self.speechThreshold {
            hasSpeech = true
            silentSamples = 0
            segment.append(contentsOf: mono)
        } else if hasSpeech {
            // Cisza PO mowie jest częścią fragmentu — bez niej whisper gubi
            // ostatnią sylabę.
            segment.append(contentsOf: mono)
            silentSamples += mono.count
        }

        let shouldCut = (hasSpeech && silentSamples >= Self.silenceSamplesToCut)
            || segment.count >= Self.maxSegmentSamples
        guard shouldCut else { return }

        let audio = segment
        resetSegment()
        transcribe(audio)
    }

    private func transcribe(_ audio: [Float]) {
        guard let context, audio.count > 8_000 else { return }  // <0,5 s to nie komenda
        let startedAt = Date()
        let text = context.transcribeFull(samples: audio, language: "pl", beamSize: 1)
        guard !text.isEmpty else { return }
        DebugLog.write(
            "Ambient",
            String(format: "fragment %.1f s → %.2f s: \"%@\"", Double(audio.count) / 16_000,
                   Date().timeIntervalSince(startedAt), text)
        )
        Task { @MainActor [weak self] in self?.route(text) }
    }

    private func route(_ text: String) {
        // Nazwy celów odświeżamy przy każdym fragmencie: okna terminali
        // przychodzą i znikają w trakcie pracy.
        router = {
            var refreshed = VoiceCommandRouter(targets: targetsProvider?() ?? [])
            refreshed.restore(from: router)
            return refreshed
        }()

        switch router.consume(text) {
        case .ignore:
            break
        case .startedCollecting(let target):
            DebugLog.write("Ambient", "nasłuch dla celu „\(target)” — mów prompt")
            onStateChange?(target, "")
        case .collecting(let target, let collected):
            onStateChange?(target, collected)
        case .commit(let target, let collected):
            DebugLog.write("Ambient", "koniec — wklejam \(collected.split(separator: " ").count) słów do „\(target)”")
            onStateChange?(nil, "")
            onCommit?(target, collected)
        case .cancelled(let target):
            DebugLog.write("Ambient", "anulowano zbieranie dla „\(target)”")
            onStateChange?(nil, "")
        }
    }

    private func resetSegment() {
        segment.removeAll(keepingCapacity: true)
        silentSamples = 0
        hasSpeech = false
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSource = buffer.format
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
