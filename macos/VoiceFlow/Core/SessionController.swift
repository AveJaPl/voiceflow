import AVFoundation
import AppKit
import QuartzCore
import os.log

/// Maszyna stanów dyktowania: idle → arming → listening → finalizing → done.
/// Spina `AudioCapture`, `SpeechEngine`, `Segmenter`, `TextDiffer`, `Formatter`
/// i `TextInjecting` — to jest jedyne miejsce, które zna wszystkie naraz.
@MainActor
final class SessionController {
    enum State: Equatable {
        case idle
        case arming
        case listening
        case finalizing
        case done
        case error(String)
    }

    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "SessionController")

    private let audioCapture: AudioCapture
    private let engine: SpeechEngine
    private let segmenter: Segmenter
    private let differ: TextDiffer
    private let formatter: Formatter
    private let injector: TextInjecting & ClipboardInjecting
    private let focusProbe: FocusProbe
    private let notesStore: NotesStore
    private let ducking: DictationDucking

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    private(set) var currentText: String = "" {
        didSet { onTextChange?(currentText) }
    }

    var onStateChange: ((State) -> Void)?
    /// Pełny narastający tekst tej sesji dyktowania (to, co faktycznie trafia
    /// do dokumentu — może obejmować kilka wypowiedzi przy kontynuacji myśli).
    var onTextChange: ((String) -> Void)?
    /// TYLKO to, co powiedziano w BIEŻĄCYM wciśnięciu skrótu — do pilla. Przy
    /// kontynuacji tej samej myśli `onTextChange` rośnie od początku sesji, ale
    /// pill ma pokazywać jedynie świeżą wypowiedź, nie stary tekst sprzed kliknięcia.
    var onUtteranceTextChange: ((String) -> Void)?
    /// Poziom audio (RMS 0…1) dla waveformu w pillu. Wołane na głównym wątku.
    var onAudioLevel: ((Float) -> Void)?
    /// Log latencji: onset mowy → pierwszy widoczny tekst w polu (kryterium 4 z kontraktu).
    var onFirstTextLatency: ((TimeInterval) -> Void)?

    private var updatesTask: Task<Void, Never>?
    private var speechOnsetAt: CFTimeInterval?
    private var utteranceStartedAt: Date?
    private var reportedFirstTextLatency = false
    private(set) var currentInjectionMode: InjectionMode = .liveTyping
    private var rawTextAccumulator: String = ""
    /// Ustawienie użytkownika (§UI/SettingsView, `SettingsKeys.insertionMode`)
    /// — gdy „Pokaż w pillu, wstaw na końcu", wymuszamy schowek zawsze, nie
    /// tylko dla aplikacji z listy wyjątków `FocusProbe`.
    private static var userForcedClipboardMode: Bool {
        UserDefaults.standard.string(forKey: SettingsKeys.insertionMode) == InsertionMode.showThenInsert.rawValue
    }
    /// Czy ostatnie `applyFinal` dowiozło tekst do aplikacji docelowej.
    private var lastInjectionSucceeded = true
    /// `id` bieżącej notatki dla ciągu kontynuowanych wypowiedzi — ta sama myśl
    /// nadpisuje jedną notatkę zamiast tworzyć nową przy każdym puszczeniu skrótu.
    private var currentNoteID: UUID?

    init(
        audioCapture: AudioCapture = AudioCapture(),
        engine: SpeechEngine,
        segmenter: Segmenter = Segmenter(),
        differ: TextDiffer = TextDiffer(),
        formatter: Formatter = Formatter(),
        injector: TextInjecting & ClipboardInjecting = TextInjector(),
        focusProbe: FocusProbe = FocusProbe(),
        notesStore: NotesStore = NotesStore(),
        audioDucker: AudioDucking = AudioDucker(),
        discordMuteToggle: DiscordMuteToggling = DiscordMuteToggle(),
        discordPresence: DiscordPresenceReporting = DiscordPresence()
    ) {
        self.audioCapture = audioCapture
        self.engine = engine
        self.segmenter = segmenter
        self.differ = differ
        self.formatter = formatter
        self.injector = injector
        self.focusProbe = focusProbe
        self.notesStore = notesStore
        self.ducking = DictationDucking(ducker: audioDucker, discordMute: discordMuteToggle, presence: discordPresence)
    }

    /// Wołane RAZ przy starcie aplikacji — patrz `SpeechEngine.prewarm`.
    func prewarm() async {
        // WYŁĄCZONE 2026-08-09. `pinToCurrentDefaultInput()` (przypięcie
        // silnika do konkretnego urządzenia przez AudioUnitSetProperty) miało
        // umożliwić izolację mikrofonu przez BlackHole, ale rozjeżdża wewnętrzny
        // stan AVAudioEngine: `installTapOnBus` rzucał potem NSException →
        // SIGABRT → CAŁA APLIKACJA padała przy KAŻDYM dyktowaniu (dwa raporty
        // awarii, 17:33 i 17:36). Podstawowa funkcja jest ważniejsza niż
        // wyciszanie Discorda — wracamy do systemowego domyślnego wejścia.
        // audioCapture.pinToCurrentDefaultInput()
        do {
            try await engine.prewarm()
            startConsumingUpdates()
            log.info("SessionController prewarmed")
        } catch {
            fail("Prewarm nie powiódł się: \(error.localizedDescription)")
            log.error("Prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Zgłasza błąd i NATYCHMIAST wraca do `.idle`.
    ///
    /// `.error` jest komunikatem, nie stanem, w którym wolno utknąć. Wcześniej
    /// stan zostawał w `.error` na zawsze: pill pokazywał komunikat przez 3 s i
    /// znikał, ale `beginUtterance()` przepuszcza wyłącznie `.idle`/`.done`, więc
    /// KAŻDE następne wciśnięcie skrótu było po cichu ignorowane — bez pilla, bez
    /// nagrywania, bez śladu. Nieudany `prewarm()` przy starcie aplikacji
    /// unieruchamiał w ten sposób dyktowanie aż do restartu. Zgłoszenie
    /// 2026-08-11: „jak dyktuję, to nic się nie pojawia; czasem się pojawia,
    /// czasem nie".
    ///
    /// Dwa przejścia pod rząd są celowe i UI na nie liczy: `updatePill` pokazuje
    /// kartę błędu na `.error`, a następujące `.idle` jej nie gasi, bo gasi tylko
    /// fazy `.arming`/`.listening`/`.transcribing`.
    private func fail(_ message: String) {
        DebugLog.write("Session", "BŁĄD: \(message)")
        state = .error(message)
        state = .idle
    }

    /// Skrót wciśnięty — tylko odkręca kurek audio, sesja ASR już istnieje.
    func beginUtterance() {
        guard state == .idle || state == .done else {
            // Kiedyś ta ścieżka była niema, a stan potrafił utknąć w `.error` na
            // zawsze — skrót przestawał cokolwiek robić i nie było jak zobaczyć
            // dlaczego. `.error` już nie utyka (patrz `fail`), ale jeśli kiedyś
            // wciśnięcie znów przepadnie, log ma o tym powiedzieć wprost.
            DebugLog.write("Session", "beginUtterance POMINIĘTY — stan to \(state), nie .idle/.done")
            return
        }
        state = .arming

        let focus = focusProbe.currentFocus()
        currentInjectionMode = Self.userForcedClipboardMode ? .clipboardFallback : focus.mode

        // KAŻDE wciśnięcie skrótu to ZAWSZE nowa, niezależna wypowiedź — nie
        // doklejamy do poprzedniej, nawet przy bardzo krótkiej przerwie
        // (zgłoszenie 2026-08-10: dyktowanie do Promptera krótkimi frazami
        // sklejało się w jedno zdanie, bo wcześniej działał próg "kontynuacji
        // tej samej myśli" przy przerwie < 1,5 s — usunięty na życzenie).
        //
        // Cały stan wypowiedzi startuje od zera — łącznie z `rawTextAccumulator`,
        // bo silniki ASR czyszczą teraz swój transkrypt w `beginUtterance()`.
        // Wcześniej stan silnika narastał przez cały czas życia procesu i to
        // miejsce próbowało go odciąć, porównując prefiks tekstu sprzed skrótu.
        // Whisper rutynowo POPRAWIA już skomitowane słowa, więc prefiks
        // przestawał pasować i kod świadomie brał całość: druga wypowiedź
        // niosła w sobie pierwszą, wklejała ją ponownie i zapisywała obie w
        // jednej notatce. Przyczyna leżała w silniku i tam została naprawiona.
        differ.reset()
        currentText = ""
        currentNoteID = nil
        rawTextAccumulator = ""
        onUtteranceTextChange?("")
        DebugLog.write("Session", "beginUtterance: frontmost=\(focus.frontmostBundleID ?? "nil"), mode=\(focus.mode)")
        speechOnsetAt = nil
        reportedFirstTextLatency = false
        utteranceStartedAt = Date()

        do {
            audioCapture.onBuffer = { [weak self] buffer, _ in
                self?.engine.feed(buffer)
            }
            audioCapture.onLevel = { [weak self] level, _ in
                self?.handleLevel(level)
            }
            try audioCapture.start()
            engine.beginUtterance()
            state = .listening

            // DOPIERO TERAZ ducking/izolacja mikrofonu. Kolejność jest
            // krytyczna: `ducking.begin()` podmienia SYSTEMOWE domyślne
            // wejście audio na BlackHole. Uruchomione PRZED `audioCapture
            // .start()` wyrywało urządzenie spod nóg własnemu silnikowi —
            // `AVAudioEngine.installTap` rzucał NSException i CAŁA APLIKACJA
            // padała z SIGABRT przy każdym dyktowaniu (raport awarii
            // 2026-08-09 17:33). Najpierw łapiemy prawdziwy mikrofon, potem
            // odcinamy go reszcie systemu.
            ducking.begin()
        } catch {
            log.error("AudioCapture start failed: \(error.localizedDescription, privacy: .public)")
            // KRYTYCZNE: bez tego nieudany start zostawiał wyciszony mikrofon
            // systemowy i przyciszone audio NA ZAWSZE — `endUtterance` odbija
            // się od guardu `state == .listening` i nigdy nie cofa duckingu.
            ducking.end()
            audioCapture.stop()
            fail("Start mikrofonu nie powiódł się: \(error.localizedDescription)")
        }
    }

    /// Skrót puszczony — domykamy segment, formatujemy, wstrzykujemy finał, zapisujemy notatkę.
    func endUtterance() {
        guard state == .listening else {
            DebugLog.write("Session", "endUtterance POMINIĘTY — stan to \(state), nie .listening; cofam ducking awaryjnie")
            // Sesja nie doszła do .listening (błąd startu albo wyścig) — mimo to
            // MUSIMY cofnąć ducking/izolację mikrofonu, inaczej użytkownik
            // zostaje niesłyszalny bez żadnego sygnału dlaczego.
            ducking.end()
            return
        }
        state = .finalizing

        engine.endUtterance()
        audioCapture.stop()

        let finalRaw = differ.displayedText
        let formatted = formatter.format(finalRaw, isSentenceStart: true, endsUtterance: true)

        // Puszczenie skrótu ZANIM ASR zdążył cokolwiek zwrócić (bardzo szybkie
        // stuknięcie, albo cisza) dawało puste `formatted` — a `applyFinal`
        // i tak nadpisywało schowek pustką i wysyłało ⌘V: przy zaznaczonym
        // tekście w polu docelowym to KASOWAŁO zaznaczenie bez żadnej korzyści.
        // Zaobserwowane realnie: 9 pustych applyFinal z rzędu w jednej sesji.
        if !formatted.isEmpty {
            applyFinal(formatted)

            let duration = utteranceStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let noteID = currentNoteID ?? UUID()
            currentNoteID = noteID
            let note = Note(
                id: noteID,
                finalText: formatted,
                rawText: rawTextAccumulator.isEmpty ? finalRaw : rawTextAccumulator,
                targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                duration: duration,
                injected: lastInjectionSucceeded
            )
            notesStore.upsert(note)
        } else {
            DebugLog.write("Inject", "applyFinal pominięty — pusty tekst (nic nie rozpoznano)")
        }
        segmenter.reset()
        state = .done
        state = .idle

        // Przywrócenie głośności/mute Discorda jest ODROCZONE — dopiero jeśli w
        // ciągu progu z `DictationDucking` NIE przyjdzie kolejne `beginUtterance`
        // (kontynuacja tej samej myśli), żeby głośność nie migała między
        // kolejnymi wypowiedziami.
        ducking.end()
    }

    /// Escape podczas `.listening` (§Zadanie 2 audytu — Linux ma `voiceflow
    /// cancel`, Mac nie miał ŻADNEGO sposobu przerwać dyktowanie bez
    /// wstrzyknięcia). Mirror `endUtterance()` co do zatrzymania audio/silnika
    /// i cofnięcia duckingu/izolacji mikrofonu, ale BEZ czytania
    /// `differ.displayedText`, BEZ `formatter.format`, BEZ `applyFinal` i BEZ
    /// zapisu notatki — użytkownik dostaje ciszę, zero wstrzykniętego tekstu.
    func cancelUtterance() {
        guard state == .listening else {
            DebugLog.write("Session", "cancelUtterance POMINIĘTY — stan to \(state), nie .listening")
            return
        }
        DebugLog.write("Session", "cancelUtterance: Escape — przerywam dyktowanie bez wstrzykiwania")
        engine.endUtterance()
        audioCapture.stop()
        segmenter.reset()
        state = .idle
        ducking.end()
    }

    // MARK: - Test bez mikrofonu

    /// Przepuszcza SZTUCZNĄ hipotezę przez DOKŁADNIE tę samą ścieżkę co
    /// prawdziwe dyktowanie (`FocusProbe` → `TextDiffer` → `TextInjector`),
    /// z pominięciem tylko audio/ASR. Do diagnozy "log mówi OK, tekst się nie
    /// wkleja" bez konieczności mówienia do mikrofonu — izoluje wstrzykiwanie
    /// od jakości rozpoznawania mowy. Wywoływane z menu "Test wstrzykiwania".
    func runInjectionSelfTest() async {
        guard state == .idle || state == .done else {
            DebugLog.write("SelfTest", "pominięty — stan zajęty: \(state)")
            return
        }
        state = .arming
        let focus = focusProbe.currentFocus()
        currentInjectionMode = Self.userForcedClipboardMode ? .clipboardFallback : focus.mode
        DebugLog.write("SelfTest", "START frontmost=\(focus.frontmostBundleID ?? "nil") mode=\(focus.mode)")
        differ.reset()
        currentText = ""
        rawTextAccumulator = ""
        state = .listening

        let steps = [
            "To", "To jest", "To jest test", "To jest test wstrzykiwania",
            "To jest test wstrzykiwania bez mikrofonu"
        ]
        for step in steps {
            handle(.volatile(step))
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        handle(.committed(steps.last!))

        state = .finalizing
        let finalRaw = differ.displayedText
        let formatted = formatter.format(finalRaw, isSentenceStart: true, endsUtterance: true)
        DebugLog.write("SelfTest", "przed applyFinal, differ.displayedText=\"\(finalRaw)\"")
        applyFinal(formatted)
        state = .done
        state = .idle
        DebugLog.write("SelfTest", "KONIEC")
    }

    // MARK: - Konsumpcja strumienia ASR

    private func startConsumingUpdates() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in engine.updates {
                await self.handle(update)
            }
        }
    }

    private func handle(_ update: TranscriptUpdate) {
        switch update {
        case .volatile(let text):
            rawTextAccumulator = text
            // `differ` MUSI dostać tylko BIEŻĄCĄ wypowiedź, nie całą historię
            // trwałego silnika — inaczej drugie dyktowanie wkleja też pierwsze.
            applyLive(differ.diff(toHypothesis: utteranceLocalText(text)))
            reportUtteranceOnlyText()
            reportFirstTextLatencyIfNeeded()
        case .committed(let text):
            rawTextAccumulator = text
            let formatted = formatter.format(utteranceLocalText(text), isSentenceStart: true, endsUtterance: false)
            applyLive(differ.freeze(committedText: formatted))
            reportUtteranceOnlyText()
            reportFirstTextLatencyIfNeeded()
        case .finalized(let text):
            applyFinal(formatter.format(utteranceLocalText(text), isSentenceStart: true, endsUtterance: true))
        }
    }

    /// Hipoteza silnika dotyczy już wyłącznie bieżącej wypowiedzi — silniki
    /// czyszczą transkrypt w `beginUtterance()`. Zostaje samo przycięcie
    /// białych znaków; nic tu nie odejmujemy od tekstu.
    private func utteranceLocalText(_ fullHypothesis: String) -> String {
        fullHypothesis.trimmingCharacters(in: .whitespaces)
    }

    /// Pill dostaje hipotezę bieżącej wypowiedzi, lekko sformatowaną do
    /// wyświetlenia — nie wpływa to na `differ`/wstrzykiwanie, tylko na widok.
    private func reportUtteranceOnlyText() {
        let display = formatter.format(utteranceLocalText(rawTextAccumulator), isSentenceStart: true, endsUtterance: false)
        onUtteranceTextChange?(display)
    }

    private func handleLevel(_ rms: Float) {
        let now = CACurrentMediaTime()
        if let event = segmenter.process(rms: rms, at: now), event == .speechStarted {
            speechOnsetAt = now
        }
        onAudioLevel?(rms)
    }

    private func reportFirstTextLatencyIfNeeded() {
        guard !reportedFirstTextLatency, let onset = speechOnsetAt else { return }
        reportedFirstTextLatency = true
        let latency = CACurrentMediaTime() - onset
        onFirstTextLatency?(latency)
        log.info("Pierwszy widoczny tekst po \(latency * 1000, format: .fixed(precision: 0), privacy: .public) ms od onsetu mowy")
    }

    // MARK: - Wstrzykiwanie

    private func applyLive(_ plan: InjectionPlan) {
        guard !plan.isNoop else {
            currentText = differ.displayedText
            return
        }
        currentText = differ.displayedText
        guard currentInjectionMode == .liveTyping else { return }
        do {
            try injector.apply(plan)
            DebugLog.write("Inject", "live OK: delete=\(plan.deleteCount) insert=\"\(plan.insert)\"")
        } catch {
            log.error("Injection failed, przełączam na tryb schowka: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("Inject", "live FAILED: \(error) — przełączam na schowek")
            currentInjectionMode = .clipboardFallback
        }
    }

    private func applyFinal(_ text: String) {
        currentText = text
        // Zakładamy sukces i zdejmujemy flagę dopiero na złapanym błędzie —
        // historia ma odnotować, że tekst NIE trafił do aplikacji, bo wtedy
        // jest jedynym miejscem, z którego da się go odzyskać.
        lastInjectionSucceeded = true
        DebugLog.write("Inject", "applyFinal mode=\(currentInjectionMode) text=\"\(text)\"")
        switch currentInjectionMode {
        case .liveTyping:
            // NIE ufamy, że wszystkie pojedyncze znaki wysłane w trakcie mówienia
            // naprawdę wylądowały — CGEvent bez błędu nie znaczy bez utraty (log
            // z 2026-08-09: same "OK", a tekst w polu się nie zgadzał, zwłaszcza
            // w aplikacjach na Electronie). Na FINALE kasujemy tyle znaków, ile
            // NASZ model mówi że powinno tam być, i wklejamy poprawny tekst przez
            // schowek — to najbardziej niezawodna ścieżka jaką mamy, ta sama co
            // uniwersalny fallback, więc ostateczny wynik jest deterministyczny
            // nawet jeśli po drodze coś z żywego wpisywania nie trafiło.
            let charsToClear = differ.displayedText.count
            let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            do {
                if charsToClear > 0 {
                    try injector.apply(InjectionPlan(deleteCount: charsToClear, insert: ""))
                }
                try injector.insertViaClipboard(text)
                differ.forceSet(text)
                let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                DebugLog.write("Inject", "final: cleared \(charsToClear) chars, pasted via clipboard OK, frontmost \(frontmostBefore) -> \(frontmostAfter)")
            } catch {
                lastInjectionSucceeded = false
                log.error("Final injection failed: \(error.localizedDescription, privacy: .public)")
                DebugLog.write("Inject", "final backspace+paste FAILED: \(error)")
            }
        case .clipboardFallback:
            do {
                try injector.insertViaClipboard(text)
                DebugLog.write("Inject", "final clipboard OK")
            } catch {
                lastInjectionSucceeded = false
                DebugLog.write("Inject", "final clipboard FAILED: \(error)")
            }
        }
    }
}

protocol ClipboardInjecting {
    func insertViaClipboard(_ text: String) throws
}
extension TextInjector: ClipboardInjecting {}
