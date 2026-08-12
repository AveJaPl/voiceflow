import AppKit
import ApplicationServices
import Combine
import SwiftUI
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "App")

@main
final class AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var debugWindowController: RawDebugWindowController?
    private var sessionController: SessionController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var dictationLatch: DictationLatch?
    private var updateChecker: UpdateChecker?
    private let historyUploader = HistoryUploader()
    private let ambient = AmbientListener()
    /// Migawki okien dla trybu nasłuchu — własna instancja, żeby nasłuch nie
    /// podbijał generacji, na której opiera się telefon.
    private let ambientSnapshotter = WindowSnapshotter()
    /// Dzielona z `RemoteMicClient` (docs/plans/remote-mic-relay.md) — ten sam
    /// `AudioCapture`, który używa `SessionController` skrótu lokalnego.
    /// Trzymana tutaj jawnie (nie tylko wewnątrz `SessionController`), żeby
    /// zdalny mikrofon mógł na czas SWOJEJ wypowiedzi podstawić
    /// `startOverride`/`stopOverride` bez tworzenia drugiej instancji i bez
    /// duplikowania pipeline'u — patrz doc-comment `RemoteMicClient`.
    private var sharedAudioCapture: AudioCapture?
    private var remoteMicClient: RemoteMicClient?
    private let notesStore = NotesStore()
    private let pillController = PillWindowController()
    private var pillHideWorkItem: DispatchWorkItem?
    private let settingsModel = SettingsModel()
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?
    /// Stan, który widzi okno główne. Jedno źródło prawdy: aktualizuje je
    /// wyłącznie ten kontroler, okno samo niczego nie odpytuje.
    private lazy var uiModel = AppUIModel(store: notesStore)
    private var settingsCancellables: Set<AnyCancellable> = []
    /// Escape podczas `.listening` = anulowanie dyktowania (§Zadanie 2 audytu
    /// — Linux ma `voiceflow cancel`). Monitor GLOBALNY (nie lokalny) — VoiceFlow
    /// jest `LSUIElement` bez okna kluczowego w trakcie dyktowania (użytkownik
    /// pisze do INNEJ aplikacji), więc lokalny `NSEvent` monitor nigdy by nie
    /// zobaczył tego Escape. Zamierzony kompromis wersji "lżejszej" z zadania
    /// (zamiast osobnego `CGEventTap`): globalny monitor tylko OBSERWUJE,
    /// nie konsumuje zdarzenia — Escape leci też do aplikacji pod kursorem,
    /// akceptowalne dla klawisza, który w większości miejsc i tak nic nie robi
    /// albo zamyka coś nieistotne. Zakładany tylko na czas `.listening`.
    private var escapeMonitor: Any?
    /// Pełny narastający tekst tej sesji dyktowania — pokazywany w karcie
    /// `.result` po zakończeniu, żeby dało się go skopiować w całości.
    private var lastFullText: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("App", "=== start VoiceFlow, pid \(ProcessInfo.processInfo.processIdentifier) ===")
        // PRZED czymkolwiek innym: jeśli poprzednia sesja padła z podmienionym
        // wejściem audio, użytkownik jest teraz niesłyszalny na czatach i nie
        // wie dlaczego. Naprawiamy to sami, zanim cokolwiek zaczniemy.
        InputDeviceSwitcher().recoverIfStuck()
        setupStatusItem()
        requestAccessibilityPermissionIfNeeded()
        setupSessionController()
        setupHotkey()
        setupRemoteMic()

        // Samo-aktualizacja z GitHub Releases (kanał mac-vX.Y.Z) — patrz
        // UpdateChecker. Restart tylko w bezczynnej chwili, nigdy w trakcie
        // dyktowania.
        let updater = UpdateChecker(isBusy: { [weak self] in
            guard let state = self?.sessionController?.state else { return false }
            return state != .idle && state != .done
        })
        updateChecker = updater
        updater.start()

        // Kopia każdego dyktowania do historii konta — z niej czyta telefon.
        sessionController?.onNoteSaved = { [weak self] note in
            self?.historyUploader.upload(note)
        }
        // Jednorazowo: cała dotychczasowa lokalna historia na konto (dedup po
        // stronie klienta, flaga po komplecie).
        historyUploader.backfillIfNeeded(notes: notesStore.notes)

        setupAmbientListening()

        Task { [weak self] in
            await self?.sessionController?.prewarm()
            DebugLog.write("App", "prewarm zakończony")
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoiceFlow")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let mainItem = NSMenuItem(title: "Otwórz voiceflow", action: #selector(showMainWindow), keyEquivalent: "o")
        mainItem.target = self
        menu.addItem(mainItem)
        let settingsItem = NSMenuItem(title: "Ustawienia…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "Okno debugowania", action: #selector(showDebugWindow), keyEquivalent: "d")
        debugItem.target = self
        menu.addItem(debugItem)
        let selfTestItem = NSMenuItem(title: "Test wstrzykiwania (bez mikrofonu)", action: #selector(runInjectionSelfTest), keyEquivalent: "t")
        selfTestItem.target = self
        menu.addItem(selfTestItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Zakończ VoiceFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
    }

    @objc private func showMainWindow() {
        if mainWindow == nil {
            guard let remoteMicClient else {
                log.error("showMainWindow wołane przed setupRemoteMic — pomijam okno")
                return
            }
            let root = MainView(model: uiModel, settingsModel: settingsModel, remoteMic: remoteMicClient)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "voiceflow"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Ciemny wygląd na sztywno: paleta jest przeniesiona z Linuksa i
            // istnieje tylko w wersji ciemnej, więc jasny motyw systemu dałby
            // czarny tekst na czarnym tle.
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        uiModel.reload()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            guard let remoteMicClient else {
                log.error("showSettings wołane przed setupRemoteMic — pomijam okno")
                return
            }
            let hosting = NSHostingView(rootView: SettingsView(model: settingsModel, remoteMic: remoteMicClient))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ustawienia VoiceFlow"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func runInjectionSelfTest() {
        Task { [weak self] in
            await self?.sessionController?.runInjectionSelfTest()
        }
    }

    @objc private func showDebugWindow() {
        if debugWindowController == nil {
            debugWindowController = RawDebugWindowController()
        }
        debugWindowController?.update(notes: notesStore.notes)
        debugWindowController?.showWindow(nil)
        debugWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Uprawnienia

    /// Dostępność (Accessibility) jest potrzebna do CGEventTap (skrót) i CGEvent
    /// posting (wstrzykiwanie). Wywołanie z promptem pokazuje natywny system-owy
    /// dialog zamiast po cichu failować przy pierwszej próbie.
    private func requestAccessibilityPermissionIfNeeded() {
        let options: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        log.info("Accessibility trusted: \(trusted, privacy: .public)")
        DebugLog.write("App", "AXIsProcessTrusted = \(trusted)")
    }

    // MARK: - Rdzeń

    private func setupSessionController() {
        do {
            // Zapisany wybór języka z Ustawień; domyślnie polski. Zmiana wymaga
            // restartu aplikacji (silnik tworzy się raz, tutaj, przy starcie).
            let storedLanguage = UserDefaults.standard.string(forKey: SettingsKeys.language)
                .flatMap(DictationLanguage.init(rawValue:)) ?? .polish
            let engine = try makeSpeechEngine(for: storedLanguage)
            // Słownik użytkownika (§Zadanie 1 audytu) scalony z domyślnym RAZ,
            // przy starcie — Formatter jest tworzony jeden raz tutaj, tak samo
            // jak silnik ASR wyżej, więc zmiana w Ustawieniach wymaga restartu
            // (whisper.cpp dostaje ją NATYCHMIAST inną drogą — patrz
            // `WhisperSpeechEngine.buildInitialPrompt`, czyta UserDefaults na żywo).
            let userVocabulary = UserDefaults.standard.stringArray(forKey: SettingsKeys.customVocabulary) ?? []
            let formatter = Formatter(dictionary: Formatter.mergedDictionary(userVocabulary: userVocabulary))
            // Instancja jawna (nie domyślny argument) — `RemoteMicClient`
            // (docs/plans/remote-mic-relay.md) potrzebuje TEJ SAMEJ instancji,
            // żeby na czas zdalnej wypowiedzi podstawić `startOverride`/
            // `stopOverride` bez duplikowania pipeline'u audio.
            let audioCapture = AudioCapture()
            sharedAudioCapture = audioCapture
            let controller = SessionController(audioCapture: audioCapture, engine: engine, formatter: formatter, notesStore: notesStore)
            controller.onStateChange = { [weak self] state in
                // Dyktowanie skrótem przejmuje mikrofon — nasłuch na ten czas
                // milczy, żeby nie liczyć tego samego audio dwa razy i nie
                // złapać komendy w środku promptu.
                self?.ambient.setMuted(state != .idle && state != .done)
                self?.updateIcon(for: state)
                self?.updatePill(for: state)
                self?.updateEscapeMonitor(for: state)
                self?.updateWindow(for: state)
                self?.debugWindowController?.update(state: "\(state)")
            }
            controller.onTextChange = { [weak self] text in
                // Pełny narastający tekst (może obejmować kilka wypowiedzi przy
                // kontynuacji) — do okna debugowania i jako źródło karty wyniku
                // (`.result`) pokazywanej po zakończeniu dyktowania.
                self?.lastFullText = text
                self?.debugWindowController?.update(text: text)
            }
            controller.onUtteranceTextChange = { [weak self] utteranceText in
                guard let self, let controller = self.sessionController else { return }
                // Live typing = tekst i tak leci pod kursorem w polu docelowym,
                // pill nie ma po co go duplikować (feedback: "niech tekst będzie
                // w polu na którym jest focus, nie w tym pillu"). Pill zostaje
                // małym wskaźnikiem — ikona + fala — przez cały czas mówienia.
                // Tylko tryb schowka (Electron/IDE, gdzie NIC nie widać w polu
                // aż do końca) dostaje podgląd w pillu, bo tam nie ma innego
                // sposobu, żeby użytkownik widział cokolwiek w trakcie mówienia.
                guard controller.currentInjectionMode == .clipboardFallback else {
                    self.pillController.model.liveText = ""
                    return
                }
                self.pillController.model.liveText = utteranceText
                if !utteranceText.isEmpty, self.pillController.model.phase == .listening {
                    self.pillController.model.phase = .transcribing
                }
            }
            controller.onAudioLevel = { [weak self] level in
                self?.pillController.model.audioLevel = level
            }
            controller.onFirstTextLatency = { [weak self] latency in
                log.info("onset->pierwszy tekst: \(latency * 1000, privacy: .public) ms")
                self?.debugWindowController?.update(latencyMs: latency * 1000)
            }
            sessionController = controller
        } catch {
            log.error("Nie udało się zainicjować silnika rozpoznawania mowy: \(error.localizedDescription, privacy: .public)")
            statusItem?.button?.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "VoiceFlow — błąd")
        }
    }

    /// Angielski zawsze idzie przez Apple — poza zakresem tego zadania
    /// (docs/plans/whisper-local-engine-pl.md: dla en-US "nie ma dziś żadnego
    /// znanego problemu z tą ścieżką, nie dotykać"). Dla polskiego wybór
    /// idzie z Ustawień (`SettingsKeys.speechEngine`), domyślnie whisper.cpp —
    /// żeby awaria serwera Apple z 2026-08-10 (zero wyniku, zero błędu, patrz
    /// docs/plans/whisper-local-engine-pl.md) nie mogła się powtórzyć.
    private func makeSpeechEngine(for language: DictationLanguage) throws -> SpeechEngine {
        guard language == .polish else {
            return try AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        }
        let storedEngine = UserDefaults.standard.string(forKey: SettingsKeys.speechEngine)
            .flatMap(SpeechEngineChoice.init(rawValue:)) ?? .whisper
        switch storedEngine {
        case .whisper:
            return WhisperSpeechEngine(language: "pl")
        case .apple:
            return try AppleSpeechEngine(locale: Locale(identifier: "pl-PL"))
        }
    }

    /// Tryb nasłuchu: „terminal pierwszy nasłuchuj" → prompt → „koniec".
    /// Wyłączony domyślnie — mikrofon chodzący bez przerwy to świadoma decyzja
    /// użytkownika, nie domyślne zachowanie.
    private func setupAmbientListening() {
        ambient.targetsProvider = { [weak self] in
            guard let self else { return [] }
            let snapshot = ambientSnapshotter.snapshot()
            return TerminalRegistry
                .terminals(from: snapshot, snapshotter: ambientSnapshotter)
                .map(\.name)
        }
        ambient.onTargetLocated = { [weak self] targetName in
            guard let self, let terminal = terminal(named: targetName) else { return }
            pillController.moveOverWindow(
                x: terminal.window.x, y: terminal.window.y,
                width: terminal.window.w, height: terminal.window.h
            )
        }
        ambient.onCommit = { [weak self] targetName, text in
            self?.injectAmbient(text: text, into: targetName)
        }
        ambient.onStateChange = { [weak self] target, collected in
            // Pill pokazuje, do którego terminala leci prompt — inaczej nie
            // widać, czy komenda w ogóle została usłyszana.
            guard let self else { return }
            if let target {
                pillController.model.ambientTarget = target
                pillController.model.liveText = collected
                pillController.show()
            } else {
                pillController.model.ambientTarget = nil
                if sessionController?.state == .idle || sessionController?.state == .done {
                    pillController.hide()
                }
            }
        }
        if settingsModel.ambientEnabled {
            Task { await ambient.start() }
        }
        settingsModel.$ambientEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { Task { await self.ambient.start() } } else { ambient.stop() }
            }
            .store(in: &settingsCancellables)
    }

    /// Wklejenie promptu do nazwanego terminala — tą samą drogą co telefon:
    /// podnieś okno, POTWIERDŹ fokus, dopiero potem wklej. Bez potwierdzenia
    /// prompt trafiłby tam, gdzie akurat stoi kursor.
    /// Terminal o tej nazwie w BIEŻĄCEJ migawce, razem z jego prostokątem.
    private func terminal(named name: String) -> (terminal: TerminalRegistry.Terminal, window: WireWindow)? {
        let snapshot = ambientSnapshotter.snapshot()
        let terminals = TerminalRegistry.terminals(from: snapshot, snapshotter: ambientSnapshotter)
        guard let match = terminals.first(where: { VoiceCommandRouter.similar(
            VoiceCommandRouter.normalize($0.name), VoiceCommandRouter.normalize(name)
        ) }), let window = snapshot.windows.first(where: { $0.id == match.id }) else { return nil }
        return (match, window)
    }

    private func injectAmbient(text: String, into targetName: String) {
        guard let terminal = terminal(named: targetName)?.terminal else {
            DebugLog.write("Ambient", "nie znalazłem terminala „\(targetName)” — nic nie wklejam")
            return
        }
        Task { @MainActor in
            guard let windowID = UInt32(terminal.id),
                  await WindowFocuser.focus(windowID: windowID, pid: terminal.pid) else {
                DebugLog.write("Ambient", "nie udało się podnieść terminala „\(targetName)” — prompt zostaje w logu: \(text)")
                return
            }
            do {
                try TextInjector().insertViaClipboard(text)
                DebugLog.write("Ambient", "wklejono do „\(terminal.name)”: \(text)")
            } catch {
                DebugLog.write("Ambient", "wklejanie nie powiodło się: \(error.localizedDescription)")
            }
        }
    }

    /// Wspólne zakończenie dyktowania ze skrótu — z hold-to-talk i z zatrzasku.
    private func finishUtteranceFromHotkey() {
        sessionController?.endUtterance()
        debugWindowController?.update(notes: notesStore.notes)
    }

    private func setupHotkey() {
        let monitor = HotkeyMonitor(keyCode: settingsModel.mainHotkey.keyCode)
        // Zmiana w Ustawieniach działa natychmiast — `monitor.keyCode` jest
        // czytany na żywo w evencie (patrz komentarz w HotkeyMonitor.swift),
        // więc wystarczy podmienić wartość, bez restartu tapa/aplikacji.
        settingsModel.$mainHotkey
            .dropFirst()
            .sink { [weak monitor] hotkey in
                monitor?.keyCode = hotkey.keyCode
                DebugLog.write("App", "Skrót zmieniony na keyCode=\(hotkey.keyCode)")
            }
            .store(in: &settingsCancellables)
        // Zatrzask: podwójne stuknięcie = dyktowanie bez trzymania klawisza,
        // kolejne stuknięcie kończy. Zwykłe przytrzymanie bez zmian.
        let latch = DictationLatch()
        dictationLatch = latch
        monitor.onPressed = { [weak self] in
            switch latch.pressed(at: CACurrentMediaTime()) {
            case .begin:
                self?.sessionController?.beginUtterance()
            case .end:
                DebugLog.write("Hotkey", "zatrzask: stuknięcie kończy dyktowanie bez trzymania")
                self?.finishUtteranceFromHotkey()
            case .none:
                break
            }
        }
        monitor.onReleased = { [weak self] in
            switch latch.released(at: CACurrentMediaTime()) {
            case .end:
                self?.finishUtteranceFromHotkey()
            case .none:
                if latch.isLatched {
                    DebugLog.write("Hotkey", "zatrzask: sesja zostaje otwarta — mów bez trzymania, stuknij aby zakończyć")
                }
            case .begin:
                break
            }
        }
        monitor.onToggleChord = { [weak self] in
            guard let self, let session = self.sessionController else { return }
            if session.state == .listening {
                self.dictationLatch?.reset()
                self.finishUtteranceFromHotkey()
            } else {
                session.beginUtterance()
            }
        }
        if !monitor.start() {
            log.error("HotkeyMonitor nie wystartował — brak Dostępności/Monitorowania danych wejściowych")
            let alert = NSAlert()
            alert.messageText = "VoiceFlow potrzebuje uprawnienia Dostępność"
            alert.informativeText = "Włącz VoiceFlow w Ustawienia systemowe → Prywatność i bezpieczeństwo → Dostępność (i Monitorowanie danych wejściowych), potem uruchom aplikację ponownie."
            alert.addButton(withTitle: "Otwórz Ustawienia")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        hotkeyMonitor = monitor
    }

    /// Zdalny mikrofon (telefon) — docs/plans/remote-mic-relay.md. Wymaga
    /// `sessionController`/`sharedAudioCapture` już zainicjowanych przez
    /// `setupSessionController()` (kolejność w `applicationDidFinishLaunching`).
    /// Domyślnie WYŁĄCZONE (`SettingsKeys.remoteMicEnabled`) — `start()` sam
    /// sprawdza ten toggle i nic nie robi, jeśli nie włączony.
    private func setupRemoteMic() {
        guard let sessionController, let sharedAudioCapture else {
            log.error("setupRemoteMic wołane przed setupSessionController — pomijam")
            return
        }
        // Jednorazowy import tokenu parowania podrzuconego przez `defaults`
        // (np. skonfigurowanego skryptem/agentem). Wpis do Keychaina zrobiony
        // przez `security` z CLI ma partition-list ograniczoną do narzędzi
        // Apple i apka NIE MOŻE go odczytać — jedyna czysta droga to zapis
        // przez samą aplikację. Token jest natychmiast USUWANY z defaults;
        // na dysku zostaje wyłącznie w Keychainie.
        let importKey = "voiceflow.pairingTokenImport"
        if let imported = UserDefaults.standard.string(forKey: importKey), !imported.isEmpty {
            KeychainPairingTokenStore().saveToken(imported)
            UserDefaults.standard.removeObject(forKey: importKey)
            DebugLog.write("RemoteMic", "token parowania zaimportowany z defaults do Keychaina")
        }

        let client = RemoteMicClient(sessionController: sessionController, audioCapture: sharedAudioCapture)
        remoteMicClient = client

        settingsModel.$remoteMicEnabled
            .dropFirst()
            .sink { [weak client] _ in client?.restart() }
            .store(in: &settingsCancellables)
        settingsModel.$remoteMicHost
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak client] _ in client?.restart() }
            .store(in: &settingsCancellables)

        client.start()
    }

    /// Zakłada/zdejmuje globalny monitor Escape — TYLKO aktywny w trakcie
    /// `.listening` (patrz doc-comment `escapeMonitor`), żeby Escape nie robił
    /// nic niespodziewanego resztę czasu (np. gdy VoiceFlow jest bezczynny).
    private func updateEscapeMonitor(for state: SessionController.State) {
        switch state {
        case .listening:
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return } // Escape
                DispatchQueue.main.async {
                    DebugLog.write("App", "Escape wykryty podczas dyktowania — anuluję")
                    self?.sessionController?.cancelUtterance()
                    // Sesja nie żyje — zatrzask nie może dalej „trzymać" i
                    // traktować następnego stuknięcia jako końca dyktowania.
                    self?.dictationLatch?.reset()
                }
            }
        default:
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    /// Przekłada stan sesji na to, co pokazuje okno główne: nazwę stanu, kropkę
    /// nagrywania i odświeżenie historii po zakończonym dyktowaniu. Okno jest
    /// zwykle zamknięte — aktualizacja modelu jest wtedy i tak darmowa, a przy
    /// otwartym oknie oszczędza odpytywania.
    private func updateWindow(for state: SessionController.State) {
        switch state {
        case .idle:
            uiModel.stateTitle = "Gotowy"
            uiModel.stateDetail = ""
            uiModel.isRecording = false
        case .arming, .listening:
            uiModel.stateTitle = "Nagrywanie"
            uiModel.stateDetail = "Mów — tekst pojawi się w aktywnym oknie"
            uiModel.isRecording = true
        case .finalizing:
            uiModel.stateTitle = "Przetwarzanie"
            uiModel.stateDetail = "Domykam wypowiedź"
            uiModel.isRecording = false
        case .done:
            uiModel.stateTitle = "Gotowy"
            uiModel.stateDetail = ""
            uiModel.isRecording = false
            // Notatka jest już zapisana (SessionController robi to przed
            // przejściem w .done), więc to najwcześniejszy moment, w którym
            // historia w oknie ma co pokazać.
            uiModel.noteAdded()
        case .error(let reason):
            uiModel.stateTitle = "Błąd"
            uiModel.stateDetail = reason
            uiModel.isRecording = false
        }
    }

    /// Steruje pillem: pojawia się przy skrócie, żyje przez cały czas mówienia
    /// i transkrypcji, po zakończeniu pokazuje pełny tekst z przyciskiem
    /// kopiowania (`.result`) i dopiero po chwili znika.
    ///
    /// `SessionController` po każdej wypowiedzi przechodzi `.done` -> `.idle`
    /// DWOMA kolejnymi, natychmiastowymi przejściami — `.idle` NIE MOŻE kasować
    /// timera schowania, który dopiero co ustawił `.done`, inaczej karta wyniku
    /// znika w tej samej klatce, w której się pojawia.
    private func updatePill(for state: SessionController.State) {
        switch state {
        case .arming:
            pillHideWorkItem?.cancel()
            // NIE czyścimy liveText tutaj — przy kontynuacji tej samej myśli
            // (krótka przerwa, np. oddech) tekst rośnie dalej z tego samego
            // miejsca; SessionController sam zdecyduje, czy to świeży start.
            pillController.model.phase = .arming
            pillController.model.armTrigger += 1
            pillController.show()
        case .listening:
            pillHideWorkItem?.cancel()
            if pillController.model.liveText.isEmpty {
                pillController.model.phase = .listening
            } else {
                pillController.model.phase = .transcribing
            }
        case .finalizing:
            pillHideWorkItem?.cancel()
            pillController.model.phase = .finalizing
        case .done:
            pillHideWorkItem?.cancel()
            guard !lastFullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Nic nie rozpoznano (stuknięcie skrótu, cisza). Karta wyniku
                // wisiałaby wtedy pusta przez 6 sekund i wyglądała jak awaria —
                // lepiej po prostu zniknąć.
                pillController.hide()
                pillController.model.phase = .idle
                pillController.model.liveText = ""
                pillController.model.resultText = ""
                return
            }
            pillController.model.resultText = lastFullText
            pillController.model.phase = .result
            pillController.show()
            let work = DispatchWorkItem { [weak self] in
                self?.pillController.hide()
                self?.pillController.model.phase = .idle
                self?.pillController.model.liveText = ""
                self?.pillController.model.resultText = ""
            }
            pillHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
        case .idle:
            // Normalnie `.done` (chwilę wcześniej w tym samym cyklu) już
            // zaplanował(a) chowanie karty wyniku — nie przerywamy go. Ale
            // `.idle` osiągnięty BEZPOŚREDNIO z `.listening`/`.transcribing`/
            // `.arming` (bez przejścia przez `.finalizing`/`.done`) to
            // anulowanie przez Escape (`cancelUtterance`) — tam nikt jeszcze
            // nie zaplanował chowania pilla, więc robimy to sami, od razu.
            switch pillController.model.phase {
            case .arming, .listening, .transcribing:
                pillHideWorkItem?.cancel()
                pillController.hide()
                pillController.model.phase = .idle
                pillController.model.liveText = ""
            default:
                break
            }
        case .error(let reason):
            pillHideWorkItem?.cancel()
            pillController.model.phase = .error(reason: reason)
            pillController.show()
            let work = DispatchWorkItem { [weak self] in
                self?.pillController.hide()
                self?.pillController.model.phase = .idle
            }
            pillHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
    }

    private func updateIcon(for state: SessionController.State) {
        let symbolName: String
        switch state {
        case .idle, .done: symbolName = "mic"
        case .arming, .listening: symbolName = "mic.fill"
        case .finalizing: symbolName = "mic.badge.plus"
        case .error: symbolName = "mic.slash"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoiceFlow")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}
