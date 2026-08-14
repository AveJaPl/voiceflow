import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "RemoteSession")

/// Stan zdalnej sesji z Makiem: połączenie, lista okien, podgląd terminala i
/// jedna wypowiedź naraz.
///
/// DWIE ZASADY, KTÓRE RZĄDZĄ CAŁĄ TĄ KLASĄ:
///
/// 1. **Nie nagrywamy na sieć, dopóki Mac nie potwierdzi `started`.** Mikrofon
///    otwiera się od razu (żeby nie uciąć pierwszego słowa), ale bajty czekają
///    w buforze `MicStreamer`. Dopóki nie ma `started`, nie wiadomo nawet, czy
///    właściwe okno wyszło na front — a prompt do Clauda wklejony w okno Slacka
///    to nie jest drobna niedogodność.
///
/// 2. **Każde oczekiwanie ma timeout.** Stan bez limitu czasu to ekran, który
///    wisi na „nagrywam…", gdy Mac zasnął — najgorszy możliwy tryb awarii, bo
///    wygląda identycznie jak działanie.
@MainActor
final class RemoteSession: ObservableObject {

    // MARK: - Typy

    enum Failure: Equatable {
        case wire(WireErrorCode)
        case disconnected
        case mic(String)
        case timeout

        /// Komunikat dla człowieka. Kody z drutu tłumaczymy tutaj, w jednym
        /// miejscu — UI nigdy nie pokazuje surowego `rawValue`.
        var message: String {
            switch self {
            case .disconnected: "Połączenie z Makiem przerwane."
            case .timeout: "Mac nie odpowiedział."
            case .mic(let why): why
            case .wire(let code):
                switch code {
                case .windowGone: "To okno już nie istnieje — lista odświeżona."
                case .focusFailed: "Nie udało się przenieść okna na wierzch. Nic nie zostało wpisane."
                case .busy: "Mac jest zajęty innym dyktowaniem."
                case .notPermitted: "Mac nie ma wymaganego uprawnienia systemowego."
                case .unsupported: "Mac nie obsługuje tej operacji."
                case .macOffline: "Mac nie jest połączony."
                case .timeout: "Mac nie odpowiedział."
                default: "Nieznany błąd Maca (\(code.rawValue))."
                }
            }
        }
    }

    enum Phase: Equatable {
        /// Brak sparowanego Maca — zakładka w ogóle się nie pokazuje.
        case offline
        case connecting
        case ready
        /// Wysłano `start`, mikrofon buforuje, czekamy na zgodę Maca.
        case arming(target: String?)
        /// `started` przyszło — audio leci na sieć.
        case streaming(target: String?)
        /// Wysłano `end`, czekamy na wstrzyknięty tekst.
        case finishing(target: String?)
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .arming, .streaming, .finishing: true
            default: false
            }
        }

        /// Czy mikrofon jest otwarty — do animacji paska mówienia.
        var isRecording: Bool {
            switch self {
            case .arming, .streaming: true
            default: false
            }
        }
    }

    struct Timeouts {
        /// Round-trip przez relay to 60–150 ms. 1,5 s to margines na kiepską
        /// komórkę, a nie na uśpionego Maca — ten ma zostać wykryty, nie przeczekany.
        var arming: TimeInterval = 1.5
        /// Transkrypcja całej wypowiedzi po stronie Maca; whisper na długim
        /// zdaniu potrafi zająć kilka sekund.
        var finishing: TimeInterval = 10
        /// Jak długo widać komunikat błędu, zanim wrócimy do gotowości.
        var failedLinger: TimeInterval = 2

        static let `default` = Timeouts()
    }

    // MARK: - Stan obserwowany przez UI

    @Published private(set) var phase: Phase = .offline
    @Published private(set) var transportState: TransportState = .idle
    @Published private(set) var mac: MacHello?
    @Published private(set) var displays: [WireDisplay] = []
    @Published private(set) var windows: [WireWindow] = []
    @Published private(set) var generation = 0
    @Published private(set) var selectedWindowID: String?
    @Published private(set) var terminalLines: [String] = []
    @Published private(set) var screenshotJPEG: Data?
    /// Podgląd na żywo z Maca w trakcie mówienia.
    @Published private(set) var previewText = ""
    @Published private(set) var lastInjected: InjectedFrame?
    /// Tekst uratowany z nieudanego wstrzyknięcia (§4.5) — żeby wypowiedź nie
    /// przepadła tylko dlatego, że focus uciekł.
    @Published private(set) var rescuedText: String?

    /// Publikowane, a nie wyliczane w locie: od tego zależy, czy zakładka „Mac"
    /// w ogóle istnieje w pasku, a SwiftUI musi się o zmianie dowiedzieć.
    @Published private(set) var isPaired = false

    /// Poświadczenia tylko do odczytu. Pulpit i Historia wołają HTTP API konta
    /// (`AccountAPI`) TYM SAMYM tokenem, którym sesja rozmawia po WebSockecie —
    /// nie ma drugiego źródła prawdy o tym, kto jest zalogowany.
    var accountCredentials: RemoteCredentials? { credentials }

    var selectedWindow: WireWindow? {
        guard let selectedWindowID else { return nil }
        return windows.first { $0.id == selectedWindowID }
    }

    // MARK: - Zależności

    private let transport: ControlTransport
    private let mic: MicStreaming
    private let haptics: HapticsProviding
    private let store: RemoteCredentialStoring
    private let timeouts: Timeouts
    private let deviceName: String

    private var credentials: RemoteCredentials?
    private var viewportActive = false
    private var pendingScreenshot: ScreenshotHeader?
    private var terminalSeq = -1
    private var armingTimeout: Task<Void, Never>?
    private var finishingTimeout: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?

    init(
        store: RemoteCredentialStoring = KeychainCredentialStore(),
        transport: ControlTransport? = nil,
        mic: MicStreaming? = nil,
        // `nil`, a nie `SystemHaptics()` w domyślnym argumencie: argumenty domyślne
        // są liczone po stronie WOŁAJĄCEGO, czyli poza izolacją MainActor.
        haptics: HapticsProviding? = nil,
        timeouts: Timeouts = .default,
        deviceName: String = "iPhone"
    ) {
        self.store = store
        self.mic = mic ?? MicStreamer()
        self.haptics = haptics ?? SystemHaptics()
        self.timeouts = timeouts
        self.deviceName = deviceName
        // Poświadczenia z argumentów uruchomienia mają pierwszeństwo i NIE trafiają
        // do Keychaina — to furtka wyłącznie do weryfikacji w symulatorze
        // (`LaunchOverrides`), pusta w buildzie Release.
        self.credentials = LaunchOverrides.credentials ?? store.load()
        self.isPaired = self.credentials != nil

        // Domyślny transport czyta poświadczenia LENIWIE, przy każdej próbie
        // połączenia — dzięki temu przeparowanie w Ustawieniach działa bez
        // przebudowywania sesji.
        if let transport {
            self.transport = transport
        } else {
            var latest: RemoteCredentials? = self.credentials
            self.transport = WebSocketTransport(urlProvider: { [weak store] in
                latest = store?.load() ?? latest
                guard let latest else { return nil }
                return RemotePairing.relayURL(latest)
            })
        }

        wireTransport()
    }

    private func wireTransport() {
        transport.onText = { [weak self] text in self?.handle(WireCodec.decodeMacFrame(text)) }
        transport.onBinary = { [weak self] data in self?.handleBinary(data) }
        transport.onState = { [weak self] state in self?.handle(state) }
    }

    // MARK: - Cykl życia

    func connect() {
        guard credentials != nil else {
            phase = .offline
            return
        }
        phase = .connecting
        transport.connect()
    }

    /// Apka wróciła na wierzch: gniazdo mogło umrzeć w tle bez żadnego błędu,
    /// a odczekiwanie backoffu z ekranem w ręce wygląda jak awaria. Ponawiamy
    /// natychmiast zamiast czekać.
    func wakeUp() {
        guard credentials != nil else { return }
        transport.reconnectNow()
        send(.requestWindows)
    }

    func disconnect() {
        cancelDictation()
        transport.disconnect()
        phase = credentials == nil ? .offline : .connecting
    }

    /// Wołane, gdy zakładka „Mac" pojawia się i znika. Steruje subskrypcją, czyli
    /// tym, czy Mac w ogóle coś wysyła — cała oszczędność baterii i transferu
    /// (plan §3.3) siedzi w tej jednej metodzie.
    func setViewportActive(_ active: Bool) {
        viewportActive = active
        syncSubscription()
        if active { send(.requestWindows) }
    }

    /// Apka schodzi w tło. Trwająca wypowiedź jest ANULOWANA, nie porzucona —
    /// Mac musi wiedzieć, że nie doczeka się `end`, bo inaczej zostaje z otwartą
    /// sesją i blokuje kolejne dyktowanie komunikatem `busy`.
    func enterBackground() {
        if phase.isBusy { cancelDictation() }
        viewportActive = false
        syncSubscription()
    }

    func updateCredentials(_ new: RemoteCredentials?) {
        transport.disconnect()
        credentials = new
        isPaired = new != nil
        if let new {
            store.save(new)
            connect()
        } else {
            store.clear()
            phase = .offline
            resetDesktopState()
        }
    }

    // MARK: - Komendy

    func select(windowID: String?) {
        guard selectedWindowID != windowID else { return }
        selectedWindowID = windowID
        terminalLines = []
        terminalSeq = -1
        syncSubscription()
    }

    func focus(_ window: WireWindow) {
        select(windowID: window.id)
        send(.focusWindow(id: window.id, generation: generation))
    }

    func move(_ window: WireWindow, to rect: (x: Int, y: Int, w: Int, h: Int)) {
        guard mac?.caps.move ?? true else { return }
        send(.moveWindow(MoveFrame(
            id: window.id, generation: generation,
            x: rect.x, y: rect.y, w: rect.w, h: rect.h
        )))
    }

    func requestScreenshot() {
        guard mac?.caps.screenshot ?? true else { return }
        send(.requestScreenshot)
    }

    /// Naciśnięcie klawisza na Macu. Domyślnie leci do ZAZNACZONEGO okna —
    /// Mac je najpierw podnosi i weryfikuje, więc ⌘V z pilota nie może wpaść
    /// w cudze okno tylko dlatego, że coś przeskoczyło na front.
    func sendKey(_ chord: KeyChord, toSelectedWindow: Bool = true) {
        let target = toSelectedWindow ? selectedWindowID : nil
        send(.key(chord: chord, target: target, generation: target == nil ? nil : generation))
    }

    /// Zmiana pulpitu na Macu. OSOBNA ramka, nie klawisz: syntetyczne ⌃←/⌃→
    /// nie przełączają pulpitów (zmierzone 2026-08-14) — Mac robi to inną drogą.
    func stepSpace(_ offset: Int) {
        send(.space(offset: offset))
    }

    /// Przeskok fokusu na sąsiedni terminal (pilot: ◀ ▶). Zwraca okno, na które
    /// przeszliśmy — widok pokazuje jego nazwę bez czekania na ramkę z Maca.
    @discardableResult
    func stepTerminal(_ offset: Int) -> WireWindow? {
        guard let window = TerminalOrder.step(from: selectedWindowID, in: windows, offset: offset) else {
            return nil
        }
        focus(window)
        return window
    }

    /// Początek wypowiedzi. `target == nil` = „dyktuj do tego, co na froncie"
    /// (zachowanie zgodne ze starszym Makiem, który nie zna okien).
    func beginDictation(target: String?) {
        guard case .ready = phaseIgnoringFailure else {
            log.info("start zignorowany — sesja nie jest gotowa (\(String(describing: self.phase)))")
            return
        }
        lingerTask?.cancel()
        previewText = ""
        rescuedText = nil
        lastInjected = nil
        phase = .arming(target: target)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await mic.startBuffering()
            } catch {
                fail(.mic(error.localizedDescription))
                return
            }
            // Sprawdzamy PONOWNIE: między otwarciem mikrofonu a tym miejscem
            // user mógł puścić palec albo apka mogła zejść w tło.
            guard case .arming = phase else {
                mic.stop()
                return
            }
            // Druga, niezależna bramka na TEN SAM niezmiennik: `MicStreamer` już
            // trzyma bajty w buforze do czasu `flushAndStream()`, ale to jest
            // jedyne miejsce w apce, przez które audio wychodzi na sieć, więc
            // pilnuje fazy jeszcze raz. Jeśli którakolwiek warstwa się pomyli,
            // druga i tak nie przepuści ani jednej próbki przed `started`.
            mic.onChunk = { [weak self] data in
                guard let self, case .streaming = phase else { return }
                transport.send(binary: data)
            }
            send(.start(target: target, generation: target == nil ? nil : generation))
            startArmingTimeout()
        }
    }

    func endDictation() {
        switch phase {
        case .streaming(let target):
            mic.stop()
            send(.end)
            phase = .finishing(target: target)
            startFinishingTimeout()
        case .arming:
            // Puszczone zanim Mac zdążył potwierdzić — nie ma czego kończyć,
            // ale Mac mógł już otworzyć sesję, więc musi dostać `cancel`.
            cancelDictation()
        default:
            break
        }
    }

    func cancelDictation() {
        guard phase.isBusy else { return }
        clearTimeouts()
        mic.onChunk = nil
        mic.stop()
        send(.cancel)
        phase = .ready
        previewText = ""
    }

    // MARK: - Ramki z Maca

    func handle(_ frame: MacFrame) {
        switch frame {
        case .hello(let hello):
            mac = hello
            if hello.protocol != Wire.protocolVersion {
                log.error("Mac mówi protokołem \(hello.protocol), telefon \(Wire.protocolVersion)")
            }
            syncSubscription()
            // Lista okien od razu po powitaniu, nie dopiero po wejściu w
            // zakładkę: gdy Wojtek tam wchodzi, terminale mają już być.
            send(.requestWindows)

        case .windows(let payload):
            apply(payload)

        case .screenshot(let header):
            pendingScreenshot = header

        case .terminal(let payload):
            // Ramka dla innego okna albo spóźniona po zmianie celu — do kosza.
            // Bez tego po przełączeniu terminala przez chwilę widać cudzą treść.
            guard payload.id == selectedWindowID, payload.seq > terminalSeq else { return }
            terminalSeq = payload.seq
            terminalLines = payload.lines

        case .focus:
            break  // czysto informacyjna; stan okien bierzemy z `windows`

        case .started(let target):
            handleStarted(target: target)

        case .preview(let text):
            guard phase.isRecording || isFinishing else { return }
            previewText = text

        case .injected(let payload):
            clearTimeouts()
            lastInjected = payload
            if !payload.text.isEmpty { previewText = payload.text }
            phase = .ready
            haptics.success()

        case .error(let payload):
            handleError(payload)

        case .unknown(let type):
            log.info("pominięto nieznaną ramkę: \(type)")
        }
    }

    private func handleStarted(target: String?) {
        guard case .arming = phase else {
            // `started` po naszym timeoucie albo po anulowaniu: Mac otworzył
            // sesję, o której my już nie wiemy. Zostawienie tego bez reakcji
            // zablokowałoby mu kolejne dyktowania błędem `busy`.
            log.info("spóźnione `started` — odsyłam `cancel`")
            send(.cancel)
            return
        }
        armingTimeout?.cancel()
        armingTimeout = nil
        phase = .streaming(target: target)
        mic.flushAndStream()
        // Dopiero TERAZ wibracja: to jedyny moment, w którym „mów" jest prawdą.
        haptics.impact()
    }

    private func handleError(_ payload: ErrorFrame) {
        if payload.code == .windowGone { send(.requestWindows) }
        if let text = payload.text, !text.isEmpty { rescuedText = text }
        fail(.wire(payload.code))
    }

    private func apply(_ payload: WindowsFrame) {
        generation = payload.generation
        displays = payload.displays
        windows = payload.windows.sorted { $0.z < $1.z }

        if let selectedWindowID, !payload.windows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
            terminalLines = []
            terminalSeq = -1
            syncSubscription()
        }
    }

    private func handleBinary(_ data: Data) {
        // Bajty obrazu są ważne WYŁĄCZNIE bezpośrednio po nagłówku `screenshot`
        // (§4.1). Binarna ramka bez nagłówka to albo błąd Maca, albo cudze dane
        // — w obu przypadkach nie ma czego wyświetlać.
        guard pendingScreenshot != nil else {
            log.error("ramka binarna bez nagłówka `screenshot` — odrzucona (\(data.count) B)")
            return
        }
        pendingScreenshot = nil
        screenshotJPEG = data
    }

    private func handle(_ state: TransportState) {
        transportState = state
        switch state {
        case .connected:
            send(.hello(PhoneHello(device: deviceName)))
            send(.requestWindows)
            syncSubscription()
            if !phase.isBusy { phase = .ready }
        case .connecting:
            if !phase.isBusy { phase = .connecting }
        case .waiting, .failed:
            // Zerwane połączenie w trakcie mówienia: nie ma szans na `injected`,
            // więc zamiast czekać do timeoutu mówimy to wprost.
            if phase.isBusy {
                mic.onChunk = nil
                mic.stop()
                clearTimeouts()
                fail(.disconnected)
            } else if credentials != nil {
                phase = .connecting
            }
        case .idle:
            if !phase.isBusy { phase = credentials == nil ? .offline : .connecting }
        }
    }

    // MARK: - Timeouty

    private func startArmingTimeout() {
        armingTimeout?.cancel()
        armingTimeout = Task { [weak self, timeouts] in
            try? await Task.sleep(nanoseconds: UInt64(timeouts.arming * 1_000_000_000))
            guard !Task.isCancelled, let self, case .arming = phase else { return }
            log.error("Mac nie potwierdził startu w \(timeouts.arming) s")
            mic.onChunk = nil
            mic.stop()          // bufor przepada — na sieć nie poszła ani jedna próbka
            send(.cancel)
            fail(.timeout)
        }
    }

    private func startFinishingTimeout() {
        finishingTimeout?.cancel()
        finishingTimeout = Task { [weak self, timeouts] in
            try? await Task.sleep(nanoseconds: UInt64(timeouts.finishing * 1_000_000_000))
            guard !Task.isCancelled, let self, isFinishing else { return }
            log.error("Mac nie odesłał wyniku w \(timeouts.finishing) s")
            // Podgląd ZOSTAJE na ekranie — to wszystko, co zostało z wypowiedzi.
            if !previewText.isEmpty { rescuedText = previewText }
            fail(.timeout)
        }
    }

    private func clearTimeouts() {
        armingTimeout?.cancel(); armingTimeout = nil
        finishingTimeout?.cancel(); finishingTimeout = nil
    }

    private func fail(_ failure: Failure) {
        clearTimeouts()
        mic.onChunk = nil
        mic.stop()
        phase = .failed(failure)
        haptics.error()
        lingerTask?.cancel()
        lingerTask = Task { [weak self, timeouts] in
            try? await Task.sleep(nanoseconds: UInt64(timeouts.failedLinger * 1_000_000_000))
            guard !Task.isCancelled, let self, case .failed = phase else { return }
            phase = transportState == .connected ? .ready : .connecting
        }
    }

    // MARK: - Pomocnicze

    /// `.failed` traktujemy jak gotowość: user ma móc od razu spróbować jeszcze
    /// raz, bez czekania, aż komunikat sam zniknie.
    private var phaseIgnoringFailure: Phase {
        if case .failed = phase, transportState == .connected { return .ready }
        return phase
    }

    private var isFinishing: Bool {
        if case .finishing = phase { return true }
        return false
    }

    private func syncSubscription() {
        guard transportState == .connected else { return }
        let terminalID = selectedWindow?.isTerminal == true ? selectedWindowID : nil
        send(.subscribe(SubscribeFrame(
            windows: viewportActive,
            screenshot: viewportActive && (mac?.caps.screenshot ?? false),
            terminal: viewportActive ? terminalID : nil
        )))
    }

    private func resetDesktopState() {
        windows = []; displays = []; generation = 0
        selectedWindowID = nil; terminalLines = []; terminalSeq = -1
        screenshotJPEG = nil; previewText = ""; lastInjected = nil; rescuedText = nil
    }

    private func send(_ frame: PhoneFrame) {
        guard let text = try? WireCodec.encodeToString(frame) else {
            log.error("nie udało się zakodować ramki \(frame.type)")
            return
        }
        transport.send(text: text)
    }
}

// MARK: - Haptyka

/// Haptyka jest tu funkcjonalna, nie ozdobna: telefon leży w dłoni, a wzrok jest
/// na ekranie Maca albo w powietrzu. Wibracja to jedyny sygnał „mikrofon
/// naprawdę żyje", który dociera bez patrzenia.
@MainActor
protocol HapticsProviding {
    /// Mac potwierdził start — MOŻNA mówić.
    func impact()
    func success()
    func error()
}

@MainActor
struct SystemHaptics: HapticsProviding {
    func impact() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

@MainActor
struct SilentHaptics: HapticsProviding {
    func impact() {}
    func success() {}
    func error() {}
}
