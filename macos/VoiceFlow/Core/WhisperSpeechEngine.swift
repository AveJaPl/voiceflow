import AVFoundation
import os.log

/// `SpeechEngine` na whisper.cpp — lokalnie, offline, zero sieci po pobraniu
/// modelu. Patrz `docs/plans/whisper-local-engine-pl.md`: dodany po awarii
/// 2026-08-10, w której `AppleSpeechEngine` (wyłącznie serwerowa ścieżka dla
/// pl-PL) przestał zwracać cokolwiek, bez żadnego błędu do złapania w kodzie.
/// Domyślny silnik dla polskiego od tego zadania — Apple zostaje dostępny
/// jako opcja w Ustawieniach (`SettingsView.swift`).
///
/// Architektura sesji TA SAMA co `AppleSpeechEngine`: TRWAŁA przez cały czas
/// życia silnika (bufor audio i stan lokalnej zgody rosną nieprzerwanie),
/// `beginUtterance`/`endUtterance` TYLKO odkręcają/zakręcają kurek — kontrakt
/// `SpeechEngine` wymaga tego wprost, żeby `SessionController` (w tym
/// kontynuacja tej samej myśli po krótkiej przerwie, `UtteranceBaselineTests`)
/// działał identycznie dla obu silników, bez zmian.
///
/// Streaming: okno dekodowania rośnie od ostatniego commitu (nie od zera przy
/// każdym kroku — patrz `decodeStepIfNeeded`), krok co `stepMs`≈300 ms, cel
/// wielkości okna `windowMs`≈2000 ms — wartości zmierzone w sondzie
/// `tools/probes/etap0e-whispercpp` (`etap0e-wyniki.md` §3: p50 pierwszego
/// partiala 430 ms dla `base` przy tej konfiguracji). Lokalna zgoda
/// (`LocalAgreement`) — DWA kolejne okna muszą się zgodzić na wspólnym
/// prefiksie słów, zanim tekst przestaje być `.volatile`. Sonda referencyjna
/// świadomie NIE implementowała tego kroku (`etap0e-wyniki.md` §6), więc to
/// jest pierwsza realna implementacja, nie przeniesienie gotowego kodu.
final class WhisperSpeechEngine: SpeechEngine {
    private let log = Logger(subsystem: "pl.programo.voiceflow", category: "WhisperSpeechEngine")
    private let queue = DispatchQueue(label: "pl.programo.voiceflow.whisper", qos: .userInteractive)

    private let language: String
    private let defaults: UserDefaults
    private var context: WhisperContext?

    /// TA SAMA wartość co `SettingsKeys.customVocabulary` (UI/SettingsView.swift)
    /// — zduplikowana tutaj, nie zaimportowana, bo Core nie zależy od UI (patrz
    /// ten sam wzorzec w `AudioDucker`/`DiscordMuteToggle`).
    private static let customVocabularyKey = "voiceflow.customVocabulary"

    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    let updates: AsyncStream<TranscriptUpdate>

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    // MARK: - Stan bufora (czytany/zmieniany WYŁĄCZNIE na `queue`)

    private var isFeeding = false
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Próbki 16 kHz mono, od `discardedSampleCount` (indeks absolutny) w górę —
    /// starsze, już skomitowane audio jest fizycznie usuwane z pamięci
    /// (`trim()`), bo sesja jest TRWAŁA przez cały czas życia silnika i bez
    /// przycinania bufor rósłby bez ograniczeń.
    private var samples: [Float] = []
    private var discardedSampleCount = 0
    private var committedSampleCount = 0
    private var lastDecodedSampleCount = 0
    private var committedText = ""
    private let agreement = LocalAgreement()

    private let stepMs = 300
    private let windowMs = 2000
    /// Mały margines bezpieczeństwa odejmowany od PROPORCJONALNEGO szacunku
    /// granicy audio w `decodeStepIfNeeded` — chroni przed cięciem dokładnie w
    /// połowie ostatniej sylaby. CELOWO mały (ułamek typowego słowa, nie cała
    /// fraza) — patrz komentarz przy `decodeStepIfNeeded` o buggu, który
    /// spowodował zbyt duży margines (700 ms, tyle co całe krótkie zdanie).
    private let safetyTailMs = 120

    private var stepSamples: Int { stepMs * 16_000 / 1000 }
    private var safetyTailSamples: Int { safetyTailMs * 16_000 / 1000 }

    init(language: String = "pl", defaults: UserDefaults = .standard) {
        self.language = language
        self.defaults = defaults
        var cont: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    // MARK: - SpeechEngine

    func prewarm() async throws {
        let modelURL = try await WhisperModelProvisioner.ensureModelAvailable()

        let rssBefore = ProcessMemory.residentBytes()
        DebugLog.write("WhisperEngine", "RSS przed załadowaniem modelu: \(rssBefore / 1_000_000) MB")

        let loaded = try await Task.detached(priority: .userInitiated) {
            try WhisperContext.load(modelPath: modelURL.path)
        }.value

        let rssAfter = ProcessMemory.residentBytes()
        let deltaMB = (Int64(rssAfter) - Int64(rssBefore)) / 1_000_000
        DebugLog.write("WhisperEngine", "RSS po załadowaniu modelu: \(rssAfter / 1_000_000) MB (Δ\(deltaMB) MB)")
        log.info("WhisperSpeechEngine prewarmed, model=\(modelURL.lastPathComponent, privacy: .public)")

        queue.sync { self.context = loaded }
    }

    func beginUtterance() {
        queue.async { [weak self] in
            self?.isFeeding = true
        }
    }

    func endUtterance() {
        queue.async { [weak self] in
            self?.isFeeding = false
            // Best-effort: dobij ostatni kawałek audio od razu, nie czekając
            // na kolejny pełny `stepMs` — zmniejsza (nie eliminuje: patrz
            // raport agenta o synchronicznym odczycie `differ.displayedText`
            // zaraz po `SessionController.endUtterance()`) opóźnienie ostatnich
            // słów wypowiedzi względem momentu puszczenia skrótu.
            self?.decodeStepIfNeeded(force: true)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, self.isFeeding else { return }
            guard let mono = self.resample(buffer) else { return }
            self.samples.append(contentsOf: mono)
            self.decodeStepIfNeeded(force: false)
        }
    }

    // MARK: - Dekodowanie (WOŁANE WYŁĄCZNIE na `queue`)

    private func decodeStepIfNeeded(force: Bool) {
        guard let context else { return }
        let currentAbsolute = discardedSampleCount + samples.count
        guard currentAbsolute > committedSampleCount else { return }
        guard force || currentAbsolute - lastDecodedSampleCount >= stepSamples else { return }
        lastDecodedSampleCount = currentAbsolute

        let localStart = committedSampleCount - discardedSampleCount
        guard localStart >= 0, localStart < samples.count else { return }
        let windowSlice = Array(samples[localStart...])

        // Ostatnie kilka skomitowanych słów jako kontekst zszywania — patrz
        // doc-comment `WhisperContext.transcribe`, redukuje halucynacje
        // powtórzeń na krótkich, oderwanych oknach. Słownik użytkownika
        // (§Zadanie 1 audytu) dochodzi jako PIERWSZA część tego samego
        // promptu — NIE zastępuje zszywania kontekstu, tylko je poprzedza.
        let promptWords = committedText.split(whereSeparator: { $0.isWhitespace }).suffix(8)
        let stitchContext = promptWords.joined(separator: " ")
        let vocabulary = defaults.stringArray(forKey: Self.customVocabularyKey) ?? []
        let prompt = Self.buildInitialPrompt(vocabulary: vocabulary, stitchContext: stitchContext)
        let rawHypothesis = context.transcribe(samples: windowSlice, language: language, initialPrompt: prompt)
        // Siatka bezpieczeństwa NIEZALEŻNA od precyzji przycinania audio wyżej
        // (`trim()`): przycinanie próbką jest tylko SZACUNKIEM (proporcja słów
        // w oknie), więc czasem wciąż zostawi w buforze ogon audio, który
        // pokrywa się z końcówką już skomitowanego tekstu — whisper go wtedy
        // dekoduje PONOWNIE (czasem z inną wielkością liter na starcie nowego
        // okna). Zamiast gonić idealną precyzję cięcia próbek (wymagałoby
        // znaczników czasu per-token z whisper.cpp), czyścimy na poziomie
        // TEKSTU: jeśli hipoteza zaczyna się od powtórki końcówki tego, co już
        // skomitowane, ucinamy tę powtórkę PRZED local-agreement. Znalezione
        // realnie w `testTranscribesWavFixtureInRealTime` ("Dzień dobry. Dzień
        // dobry." / "dzisiaj Dzisiaj" / "o o").
        let hypothesis = Self.stripRepeatedPrefix(of: rawHypothesis, alreadyCommitted: committedText)
        let step = agreement.observe(hypothesis: hypothesis)

        if !step.newlyCommitted.isEmpty {
            committedText = Self.join(committedText, step.newlyCommitted)
            // Przycinamy audio PROPORCJONALNIE do udziału skomitowanych słów w
            // oknie — NIE stałym marginesem od "teraz" (pierwsza wersja tego
            // wzoru robiła dokładnie to, marginesem 700 ms, i miała realny bug:
            // krótkie zdanie typu "Dzień dobry" trwa akustycznie krócej niż
            // 700 ms, więc margines cofał się PRZED jego początek, cała fraza
            // zostawała w buforze, kolejne okno dekodowało ją PONOWNIE i
            // local-agreement komitował ją DRUGI RAZ — zaobserwowane w
            // `testTranscribesWavFixtureInRealTime`: "Dzień dobry. Dzień
            // dobry." zamiast raz). Szacunek "tyle ułamka okna, ile ułamek
            // słów jest skomitowany" skaluje się z treścią zamiast z sztywnym
            // czasem, więc nie potrafi już cofnąć się PRZED początek świeżo
            // skomitowanej frazy. Dodatkowo mały margines (`safetyTailMs`,
            // teraz krótszy niż jedno typowe słowo) chroni przed cięciem
            // dokładnie w połowie ostatniej sylaby.
            let windowLength = currentAbsolute - committedSampleCount
            let committedWordCount = step.newlyCommitted.split(whereSeparator: { $0.isWhitespace }).count
            let volatileWordCount = step.volatile.split(whereSeparator: { $0.isWhitespace }).count
            let totalWordCount = committedWordCount + volatileWordCount
            if windowLength > 0, totalWordCount > 0 {
                let estimatedCommittedLength = windowLength * committedWordCount / totalWordCount
                let safeCut = committedSampleCount + max(0, estimatedCommittedLength - safetyTailSamples)
                committedSampleCount = min(max(committedSampleCount, safeCut), currentAbsolute)
                trim()
            }
            continuation?.yield(.committed(committedText))
            DebugLog.write("WhisperEngine", "commit: \"\(committedText)\"")
        }
        let volatileText = Self.join(committedText, step.volatile)
        continuation?.yield(.volatile(volatileText))
    }

    /// Usuwa z pamięci audio starsze niż `committedSampleCount` — bez tego
    /// bufor rósłby bez ograniczeń przez cały czas życia procesu (sesja jest
    /// TRWAŁA). Bezpieczne: okno dekodowania zawsze zaczyna się od
    /// `committedSampleCount` w górę, nigdy wcześniej.
    private func trim() {
        let localCut = committedSampleCount - discardedSampleCount
        guard localCut > 0, localCut <= samples.count else { return }
        samples.removeFirst(localCut)
        discardedSampleCount = committedSampleCount
    }

    /// Buduje `initial_prompt` z DWÓCH źródeł naraz (§Zadanie 1 audytu — Linux
    /// wpycha `model.vocabulary` WPROST do dekodera, silniejszy mechanizm niż
    /// korekta wielkości liter po fakcie w `Formatter`): słowa własne
    /// użytkownika jako pierwsza część, PLUS istniejący `stitchContext`
    /// (ostatnie skomitowane słowa tej sesji, patrz `decodeStepIfNeeded`).
    /// `internal`, nie `private` — testowana bezpośrednio jako czysta funkcja,
    /// bez ładowania modelu whisper.cpp.
    static func buildInitialPrompt(vocabulary: [String], stitchContext: String) -> String {
        let cleanVocabulary = vocabulary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var parts: [String] = []
        if !cleanVocabulary.isEmpty {
            parts.append("Słownictwo: " + cleanVocabulary.joined(separator: ", ") + ".")
        }
        if !stitchContext.isEmpty {
            parts.append(stitchContext)
        }
        return parts.joined(separator: " ")
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return "\(a) \(b)"
    }

    /// Ucina z początku `hypothesis` słowa, które powtarzają KOŃCÓWKĘ
    /// `committed` (porównanie bez wielkości liter/interpunkcji — whisper
    /// czasem kapitalizuje pierwsze słowo nowego okna, co inaczej złamałoby
    /// proste porównanie znak-w-znak). Patrz komentarz w `decodeStepIfNeeded`.
    private static func stripRepeatedPrefix(of hypothesis: String, alreadyCommitted committed: String) -> String {
        let committedWords = committed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !committedWords.isEmpty else { return hypothesis }
        let newWords = hypothesis.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !newWords.isEmpty else { return hypothesis }

        let maxOverlap = min(newWords.count, committedWords.count)
        for n in stride(from: maxOverlap, through: 1, by: -1) {
            let committedSuffix = committedWords.suffix(n)
            let newPrefix = newWords.prefix(n)
            if zip(committedSuffix, newPrefix).allSatisfy({ normalize($0) == normalize($1) }) {
                return newWords.dropFirst(n).joined(separator: " ")
            }
        }
        return hypothesis
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Resampling do 16 kHz mono (whisper.cpp wymaga dokładnie tego formatu;
    // `AudioCapture` dostarcza bufor w formacie natywnym sprzętu, patrz jego doc-comment)

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, let channelData = outBuffer.floatChannelData else {
            log.error("Konwersja audio do 16kHz nie powiodła się: \(conversionError?.localizedDescription ?? "?", privacy: .public)")
            return nil
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}
