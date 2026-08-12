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
    /// Wołane, gdy nasłuch zaczyna zbierać dla celu — do przesunięcia pilla
    /// nad właściwe okno.
    var onTargetLocated: ((_ target: String) -> Void)?
    /// Skąd wziąć aktualne nazwy terminali (odświeżane przy każdym starcie zbierania).
    var targetsProvider: (() -> [String])?

    private let capture = AudioCapture()
    private let queue = DispatchQueue(label: "pl.programo.voiceflow.ambient", qos: .userInitiated)
    private var context: WhisperContext?
    private var router = VoiceCommandRouter(targets: [])
    private(set) var isRunning = false
    /// Wstrzymanie na czas dyktowania skrótem — bez zrywania sesji audio.
    /// Czytane i zmieniane WYŁĄCZNIE na `queue`.
    private var isMutedFlag = false
    /// Czy pętla audio ma pracować — zmieniane na `queue`, czytane w `feed`.
    private var isFeeding = false

    // Bufor bieżącego wypowiedzenia (16 kHz mono) i detektor ciszy.
    private var segment: [Float] = []
    private var silentSamples = 0
    private var hasSpeech = false

    /// Próg energii uznawany za mowę. Zmierzony na mikrofonie MacBooka: szum
    /// pokoju daje ~0,004 RMS, cicha mowa ~0,03.
    private static let speechThreshold: Float = 0.006
    /// Tyle ciszy kończy fragment (600 ms) — krócej cięłoby w środku zdania.
    private static let silenceSamplesToCut = 9_600
    /// Twarde okno: fragment idzie do dekodera po tylu sekundach NIEZALEŻNIE od
    /// ciszy. Zmierzone na żywo u Wojtka: w pokoju z muzyką/rozmową energia
    /// NIGDY nie spada poniżej progu, więc cięcie „po ciszy" nie następowało
    /// wcale i komenda czekała aż do bezpiecznika 20 s — z zewnątrz wyglądało
    /// to dokładnie jak „nic się nie dzieje".
    private static let maxSegmentSamples = 4 * 16_000

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    // Diagnostyka: bez niej „nic się nie dzieje" jest nierozróżnialne od
    // „audio nie dochodzi", „za cicho" i „whisper nic nie rozpoznał".
    /// 1,5 s ogona poprzedniego okna, doklejane na początek następnego.
    private var overlapTail: [Float] = []
    private static let overlapSamples = 24_000

    private var heartbeatSamples = 0
    private var heartbeatPeak: Float = 0

    func start() async {
        guard !isRunning else { return }
        do {
            // `small`, świadomy kompromis zmierzony na żywo 2026-08-12:
            //   base            0,2 s/okno — komendy nierozpoznawalne po polsku
            //   small-q5        0,4 s/okno — z nachyleniem dekodera wystarcza
            //   large-v3-turbo  3,7 s/okno — słyszy najlepiej, ale NIE NADĄŻA
            //                   za strumieniem (okno trwa 4 s), więc nasłuch
            //                   zostawał coraz bardziej w tyle za mówiącym.
            // Jakość komend ratuje `initial_prompt` (patrz `commandPrompt`),
            // nie wielkość modelu.
            let modelURL = try await WhisperModelProvisioner.ensureModelAvailable(.smallQ5)
            let loaded = try await Task.detached(priority: .utility) {
                try WhisperContext.load(modelPath: modelURL.path)
            }.value
            context = loaded
            capture.onBuffer = { [weak self] buffer, _ in
                self?.queue.async { self?.feed(buffer) }
            }
            refreshCommandPrompt()
            try capture.start()
            isRunning = true
            queue.sync { self.isFeeding = true }
            DebugLog.write("Ambient", "tryb nasłuchu włączony")
        } catch {
            DebugLog.write("Ambient", "nie udało się włączyć nasłuchu: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        capture.onBuffer = nil
        isRunning = false
        queue.sync {
            self.isFeeding = false
            self.context = nil       // whisper_free na tej samej kolejce, co dekodowanie
            self.resetSegment()
        }
        router.reset()
        onStateChange?(nil, "")
        DebugLog.write("Ambient", "tryb nasłuchu wyłączony")
    }

    /// Dyktowanie skrótem przejmuje mikrofon — nasłuch milczy do jego końca.
    func setMuted(_ muted: Bool) {
        // Stan strumienia zmieniamy WYŁĄCZNIE na `queue` — inaczej main actor
        // czyściłby bufor w trakcie, gdy kolejka audio do niego dopisuje
        // (znalezione w review: realny wyścig na `segment`/`silentSamples`).
        queue.async { [weak self] in
            guard let self, self.isMutedFlag != muted else { return }
            self.isMutedFlag = muted
            if muted { self.resetSegment() }
            DebugLog.write("Ambient", muted ? "nasłuch wyciszony (dyktowanie skrótem)" : "nasłuch wznowiony")
        }
    }

    // MARK: - Strumień audio (na `queue`)

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard isFeeding, !isMutedFlag, let mono = resample(buffer) else { return }
        let energy = Self.rms(mono)

        // Puls co ~5 s: ile audio doszło i jak głośne było najgłośniejsze
        // okno. Jeśli tego nie ma w logu, problem jest PRZED nami (mikrofon,
        // uprawnienie, urządzenie wejściowe), a nie w progu ciszy.
        heartbeatSamples += mono.count
        heartbeatPeak = max(heartbeatPeak, energy)
        if heartbeatSamples >= 5 * 16_000 {
            DebugLog.write(
                "Ambient",
                String(format: "puls: %.0f s audio, szczyt głośności %.4f (próg mowy %.4f)",
                       Double(heartbeatSamples) / 16_000, heartbeatPeak, Self.speechThreshold)
            )
            heartbeatSamples = 0
            heartbeatPeak = 0
        }
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
        // Ogon poprzedniego okna wchodzi do następnego: bez tego komenda
        // przecięta granicą („terminal jeden" | „nasłuchuj") ginęła w całości,
        // bo żadna połowa nie jest komendą.
        overlapTail = Array(audio.suffix(Self.overlapSamples))
        resetSegment()
        transcribe(audio)
    }

    /// Słownik komend dla dekodera — odświeżany, gdy zmienia się lista okien.
    private var commandPrompt = ""

    private func refreshCommandPrompt() {
        let names = targetsProvider?() ?? []
        let phrases = names.prefix(6).map { "terminal \($0) nasłuchuj" }
        commandPrompt = (phrases + ["koniec", "anuluj"]).joined(separator: ", ") + "."
    }

    private func transcribe(_ audio: [Float]) {
        guard let context else {
            DebugLog.write("Ambient", "fragment odrzucony — model jeszcze się ładuje")
            return
        }
        guard audio.count > 8_000 else {
            DebugLog.write("Ambient", String(format: "fragment za krótki (%.2f s) — pomijam", Double(audio.count) / 16_000))
            return
        }  // <0,5 s to nie komenda
        let startedAt = Date()
        // `initial_prompt` z listą komend i nazw terminali: dekoder dostaje
        // słownik tego, co MOŻE paść. To jest właściwe miejsce na walkę z
        // przekręcaniem komend — o wiele skuteczniejsze niż dopasowywanie
        // przekręconego tekstu po fakcie.
        let text = context.transcribeFull(
            samples: audio, language: "pl",
            initialPrompt: commandPrompt, beamSize: 1
        )
        guard !text.isEmpty else {
            DebugLog.write("Ambient", String(format: "fragment %.1f s — whisper nic nie rozpoznał", Double(audio.count) / 16_000))
            return
        }
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
            // Widać, że fragment DOSZEDŁ, tylko nie był komendą — inaczej nie
            // da się odróżnić „nie usłyszałem" od „usłyszałem coś innego".
            DebugLog.write("Ambient", "fragment bez komendy (cele: \(targetsProvider?().joined(separator: ", ") ?? "brak"))")
        case .startedCollecting(let target):
            DebugLog.write("Ambient", "nasłuch dla celu „\(target)” — mów prompt")
            onStateChange?(target, "")
            onTargetLocated?(target)
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
        segment.append(contentsOf: overlapTail)
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
