import AVFoundation
import QuartzCore
import Speech
import os.log

/// `SpeechEngine` na `SFSpeechRecognizer` — jedyna ścieżka Apple do polskiego
/// (§3 planu). Na macOS 26.1 to ścieżka SERWEROWA (`supportsOnDeviceRecognition
/// == false` dla pl-PL): wymaga sieci i ma miękki, cichy limit ok. 60 s na żądanie.
///
/// Reguły twarde ze zmierzonych faktów (§5c, §5d — NIE zmieniać bez nowego pomiaru):
/// 1. Sesja (request+task) jest tworzona RAZ w `prewarm()` i żyje przez cały czas
///    procesu — `beginUtterance`/`endUtterance` tylko włączają/wyłączają dopływ audio.
/// 2. Rotacja żądania przy 45-50 s, na zapas przed cichym limitem ~60 s, z zakładką
///    audio ~300 ms do nowego żądania, żeby nie zgubić słowa na szwie.
/// 3. Watchdog: jeśli audio jest głośne (mowa trwa), a mimo to od kilku sekund nie
///    przyszedł żaden wynik, sesja jest uznana za martwą i rotowana natychmiast —
///    to jedyny sposób wykrycia cichej awarii limitu, bo API nic nie zgłasza.
final class AppleSpeechEngine: SpeechEngine {
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "AppleSpeechEngine")

    private let locale: Locale
    private let recognizer: SFSpeechRecognizer

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    let updates: AsyncStream<TranscriptUpdate>

    private let queue = DispatchQueue(label: "io.github.avejapl.voiceflow.asr", qos: .userInteractive)

    // Rotacja / watchdog
    private let rotationInterval: TimeInterval = 47
    private let watchdogTimeout: TimeInterval = 6
    private let watchdogLoudThreshold: Float = 0.015
    private var sessionStartedAt: TimeInterval = 0
    private var lastResultAt: TimeInterval = 0
    private var lastLoudAudioAt: TimeInterval = 0
    private var watchdogTimer: DispatchSourceTimer?
    private var isFeeding = false

    /// Ostatnie bufory audio (do zakładki na szwie przy rotacji).
    private var tailBuffers: [AVAudioPCMBuffer] = []
    private let tailBufferLimit = 12 // ~300ms przy buforach 1024 klatek / ~44-48kHz

    init(locale: Locale = Locale(identifier: "pl-PL")) throws {
        self.locale = locale
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppleSpeechEngineError.localeNotSupported
        }
        self.recognizer = recognizer
        var cont: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    enum AppleSpeechEngineError: Error {
        case localeNotSupported
        case authorizationDenied
        case recognizerUnavailable
    }

    // MARK: - SpeechEngine

    func prewarm() async throws {
        let authorized = await requestAuthorization()
        guard authorized else { throw AppleSpeechEngineError.authorizationDenied }
        guard recognizer.isAvailable else { throw AppleSpeechEngineError.recognizerUnavailable }

        queue.sync {
            startSession()
            startWatchdog()
        }
        log.info("AppleSpeechEngine prewarmed, locale=\(self.locale.identifier, privacy: .public)")
    }

    func beginUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isFeeding = true
            self.lastLoudAudioAt = CACurrentMediaTime()
            self.lastResultAt = CACurrentMediaTime()
            // Świeże żądanie na KAŻDĄ wypowiedź. `SFSpeechRecognitionResult`
            // zwraca transkrypt całego żądania narastająco, a żądanie żyło
            // dotąd między wciśnięciami skrótu (rotacja tylko co 47 s albo po
            // błędzie) — więc druga wypowiedź niosła w sobie pierwszą, wklejała
            // ją ponownie i lądowała z nią w jednej notatce.
            //
            // To NIE cofa dźwigni z `prewarm()`: kosztowne jest rozgrzanie
            // samego `SFSpeechRecognizer`, które zostaje, a nie utworzenie
            // kolejnego żądania na gotowym rozpoznawaczu. Bez zakładki z
            // `tailBuffers` — na granicy wypowiedzi stare audio jest dokładnie
            // tym, czego nie chcemy przenosić dalej.
            self.startFreshSession()
        }
    }

    /// Zamyka poprzednie żądanie i otwiera puste — bez zakładki audio.
    /// Wołane tylko na `queue`.
    private func startFreshSession() {
        let oldRequest = request
        startSession()
        oldRequest?.endAudio()
    }

    /// `nil` — silnik Apple nie ma osobnego przebiegu końcowego (transkrypcja
    /// powstaje po stronie serwera, strumieniowo), więc tekst końcowy zostaje ten,
    /// który narósł w `TextDiffer`. Kontrakt `SpeechEngine` przewiduje dokładnie
    /// ten przypadek.
    func endUtterance() async -> String? {
        queue.async { [weak self] in
            self?.isFeeding = false
        }
        return nil
    }

    func cancelUtterance() {
        queue.async { [weak self] in
            self?.isFeeding = false
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, self.isFeeding, let request = self.request else { return }
            request.append(buffer)
            self.rememberTail(buffer)

            let level = Self.rms(of: buffer)
            let now = CACurrentMediaTime()
            if level >= self.watchdogLoudThreshold {
                self.lastLoudAudioAt = now
            }

            if now - self.sessionStartedAt >= self.rotationInterval {
                self.rotateSession(reason: "scheduled 47s")
            }
        }
    }

    // MARK: - Sesja

    /// Wołane tylko na `queue`.
    private func startSession(seedingWith seedBuffers: [AVAudioPCMBuffer] = []) {
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = false

        for buffer in seedBuffers {
            newRequest.append(buffer)
        }

        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }

        request = newRequest
        task = newTask
        sessionStartedAt = CACurrentMediaTime()
        lastResultAt = sessionStartedAt
    }

    /// Wołane tylko na `queue`. Podwójny bufor: nowe żądanie startuje z zakładką
    /// z ostatnich ~300 ms audio ZANIM stare zostanie zamknięte, żeby na szwie
    /// nie było martwego okna (§5c pkt 2). Deduplikację zakładki robi `TextDiffer`
    /// przez wspólny sufiks/prefiks — nie tutaj.
    private func rotateSession(reason: String) {
        log.info("Rotating ASR session (\(reason, privacy: .public))")
        let oldRequest = request
        let seed = tailBuffers

        startSession(seedingWith: seed)

        oldRequest?.endAudio()
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastResultAt = CACurrentMediaTime()

            if let error {
                let nsError = error as NSError
                self.log.error("ASR error: \(nsError.localizedDescription, privacy: .public)")
                if self.isFeeding {
                    self.rotateSession(reason: "error: \(nsError.localizedDescription)")
                }
                return
            }

            guard let result else { return }
            if result.isFinal {
                // Interpunkcja po polsku to na nas (`addsPunctuation` nie działa
                // dla pl — zmierzone). Kropkę na końcu wypowiedzi stawia
                // Formatter; przecinki WEWNĄTRZ zdania stawiamy tu, na
                // ZAMROŻONYM już tekście (isFinal), z realnych przerw między
                // słowami w audio — bezpiecznie, bo ten tekst się już nie zmieni
                // (w przeciwieństwie do volatile, gdzie wstawiony znak zostałby
                // zaraz skasowany przy kolejnej, zmienionej hipotezie).
                let text = Self.insertPauseCommas(segments: result.bestTranscription.segments)
                self.continuation?.yield(.committed(text))
            } else {
                let text = result.bestTranscription.formattedString
                self.continuation?.yield(.volatile(text))
            }
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog()
        }
        timer.resume()
        watchdogTimer = timer
    }

    /// Wołane tylko na `queue`. Wykrywa cichą awarię limitu (§5c): mowa trwa
    /// (audio głośne niedawno), ale silnik nic nie zwrócił od `watchdogTimeout` s.
    private func checkWatchdog() {
        guard isFeeding else { return }
        let now = CACurrentMediaTime()
        let speechRecent = now - lastLoudAudioAt < watchdogTimeout
        let silentFromEngine = now - lastResultAt >= watchdogTimeout
        if speechRecent, silentFromEngine {
            rotateSession(reason: "watchdog: no result for \(watchdogTimeout)s despite audio")
        }
    }

    // MARK: - Pomocnicze

    private func rememberTail(_ buffer: AVAudioPCMBuffer) {
        tailBuffers.append(buffer)
        if tailBuffers.count > tailBufferLimit {
            tailBuffers.removeFirst(tailBuffers.count - tailBufferLimit)
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Skleja segmenty słów, wstawiając przecinek przed segmentem, który zaczyna
    /// się po zauważalnej przerwie (300–900 ms) od końca poprzedniego. To
    /// PRZYBLIŻENIE — prawdziwa interpunkcja wymaga rozumienia gramatyki, nie
    /// tylko czasu ciszy — ale mimo to jest lepsze niż całkowity brak
    /// przecinków, co dostajemy z Apple domyślnie (`addsPunctuation` nie działa
    /// dla pl — zmierzone w Etapie 0). Dolna granica 300ms odcina zwykłe
    /// przerwy międzysylabowe; górna 900ms zostawia dłuższym pauzom miejsce na
    /// kropkę stawianą gdzie indziej (koniec wypowiedzi), żeby nie było
    /// "słowo, . Słowo" — kropka i przecinek nigdy się nie nakładają, bo tu
    /// wstawiamy przecinek TYLKO poniżej progu, powyżej zostawiamy bez znaku.
    private static func insertPauseCommas(segments: [SFTranscriptionSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let commaGapRange: ClosedRange<TimeInterval> = 0.30...0.90

        var result = segments[0].substring
        for i in 1..<segments.count {
            let previous = segments[i - 1]
            let current = segments[i]
            let gap = current.timestamp - (previous.timestamp + previous.duration)
            let previousEndsWithPunctuation = previous.substring.last.map { ".!?,…".contains($0) } ?? false

            if commaGapRange.contains(gap), !previousEndsWithPunctuation {
                result += ","
            }
            result += " " + current.substring
        }
        return result
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
