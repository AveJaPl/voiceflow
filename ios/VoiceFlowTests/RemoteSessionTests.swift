import XCTest

/// Testy zachowania zdalnej sesji — bez sieci, bez mikrofonu, bez Maca.
///
/// Najważniejsze są tu testy negatywne: co się NIE dzieje, gdy coś pójdzie źle.
/// Ta funkcja pozwala zdalnie wkleić tekst i nacisnąć Enter w dowolnym oknie
/// Maca, więc „nie wysłał nic" jest ważniejszym wynikiem niż „wysłał".
@MainActor
final class RemoteSessionTests: XCTestCase {

    // MARK: - Atrapy

    final class FakeTransport: ControlTransport {
        var onText: ((String) -> Void)?
        var onBinary: ((Data) -> Void)?
        var onState: ((TransportState) -> Void)?

        private(set) var sent: [PhoneFrame] = []
        private(set) var binary: [Data] = []
        private(set) var connectCalls = 0
        private(set) var disconnectCalls = 0

        func connect() { connectCalls += 1 }
        func disconnect() { disconnectCalls += 1 }
        func send(text: String) {
            guard let frame = WireCodec.decodePhoneFrame(text) else {
                return XCTFail("telefon wysłał ramkę, której sam nie umie zdekodować: \(text)")
            }
            sent.append(frame)
        }
        func send(binary data: Data) { binary.append(data) }

        // Sterowanie z testu
        func goOnline() { onState?(.connected) }
        func drop() { onState?(.waiting(retryIn: 1)) }
        func deliver(_ frame: MacFrame) {
            guard let text = try? WireCodec.encodeToString(frame) else { return XCTFail("nie zakodowano") }
            onText?(text)
        }
        func deliverBinary(_ data: Data) { onBinary?(data) }

        func count(of type: String) -> Int { sent.filter { $0.type == type }.count }
        var last: PhoneFrame? { sent.last }
        func clearLog() { sent.removeAll(); binary.removeAll() }
    }

    final class FakeMic: MicStreaming {
        var onChunk: ((Data) -> Void)?
        var failure: Error?
        private(set) var startCalls = 0
        private(set) var flushCalls = 0
        private(set) var stopCalls = 0

        func startBuffering() async throws {
            if let failure { throw failure }
            startCalls += 1
        }
        func flushAndStream() { flushCalls += 1 }
        func stop() { stopCalls += 1 }

        /// Udaje próbki płynące z mikrofonu — sprawdzamy, czy wychodzą na sieć.
        func emit() { onChunk?(Data([1, 2, 3, 4])) }
    }

    final class FakeHaptics: HapticsProviding {
        private(set) var impacts = 0
        private(set) var successes = 0
        private(set) var errors = 0
        func impact() { impacts += 1 }
        func success() { successes += 1 }
        func error() { errors += 1 }
    }

    final class FakeStore: RemoteCredentialStoring {
        var credentials: RemoteCredentials? = RemoteCredentials(host: "ws://127.0.0.1:8091", token: "t0ken")
        func load() -> RemoteCredentials? { credentials }
        func save(_ new: RemoteCredentials) { credentials = new }
        func clear() { credentials = nil }
    }

    // MARK: - Rusztowanie

    private var transport: FakeTransport!
    private var mic: FakeMic!
    private var haptics: FakeHaptics!
    private var session: RemoteSession!

    private static let fastTimeouts = RemoteSession.Timeouts(arming: 0.08, finishing: 0.15, failedLinger: 5)

    override func setUp() async throws {
        try await super.setUp()
        transport = FakeTransport()
        mic = FakeMic()
        haptics = FakeHaptics()
        session = RemoteSession(
            store: FakeStore(), transport: transport, mic: mic,
            haptics: haptics, timeouts: Self.fastTimeouts, deviceName: "iPhone testowy"
        )
    }

    /// Przepuszcza zaplanowane zadania `MainActor` (sesja startuje mikrofon w `Task`).
    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    private func connectAndSelectDesktop() async {
        session.connect()
        transport.goOnline()
        transport.deliver(.hello(MacHello(
            mac: "Mac testowy",
            caps: MacCaps(screenshot: true, terminalText: true, move: true)
        )))
        transport.deliver(.windows(WindowsFrame(
            generation: 42,
            displays: [WireDisplay(id: 1, w: 3456, h: 2234, main: true)],
            windows: [
                WireWindow(id: "812:0", app: "Terminal", title: "claude", x: 0, y: 0, w: 1728, h: 2234,
                           z: 0, focused: true, kind: .terminal),
                WireWindow(id: "913:0", app: "Cursor", title: "kod", x: 1728, y: 0, w: 1728, h: 1117,
                           z: 1, kind: .other),
            ]
        )))
        await settle()
        transport.clearLog()
    }

    // MARK: - Ścieżka szczęśliwa

    func testPelnaWypowiedzTrafiaDoWskazanegoOkna() async throws {
        await connectAndSelectDesktop()

        session.beginDictation(target: "812:0")
        await settle()

        XCTAssertEqual(transport.last, .start(target: "812:0", generation: 42),
                       "start musi nieść CEL i GENERACJĘ — bez nich Mac nie ma jak sprawdzić, czy to wciąż to okno")
        XCTAssertEqual(mic.startCalls, 1)
        XCTAssertEqual(mic.flushCalls, 0, "bufor nie może zostać wypchnięty przed potwierdzeniem")

        transport.deliver(.started(target: "812:0"))
        await settle()

        XCTAssertEqual(session.phase, .streaming(target: "812:0"))
        XCTAssertEqual(mic.flushCalls, 1)
        XCTAssertEqual(haptics.impacts, 1, "wibracja jest sygnałem do mówienia — dopiero po potwierdzeniu")

        mic.emit()
        XCTAssertEqual(transport.binary.count, 1)

        transport.deliver(.preview(text: "napisz test"))
        XCTAssertEqual(session.previewText, "napisz test")

        session.endDictation()
        await settle()
        XCTAssertEqual(transport.count(of: "end"), 1)
        XCTAssertEqual(session.phase, .finishing(target: "812:0"))

        transport.deliver(.injected(InjectedFrame(target: "812:0", text: "napisz test", via: .clipboard)))
        await settle()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.lastInjected?.text, "napisz test")
        XCTAssertEqual(haptics.successes, 1)
    }

    // MARK: - Niezmiennik: ani jednej próbki przed potwierdzeniem

    func testAudioNieWychodziNaSiecPrzedStarted() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()

        mic.emit(); mic.emit(); mic.emit()

        XCTAssertTrue(
            transport.binary.isEmpty,
            "PCM wysłane przed `started` trafiłoby do okna, którego Mac jeszcze nie podniósł"
        )
    }

    // MARK: - Ścieżki błędu — najważniejsze jest to, czego NIE ma

    func testWindowGoneNieOtwieraMikrofonuIOdswiezaListe() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()

        transport.deliver(.error(ErrorFrame(code: .windowGone, message: "nie ma", target: "812:0")))
        await settle()

        XCTAssertEqual(session.phase, .failed(.wire(.windowGone)))
        XCTAssertTrue(transport.binary.isEmpty, "po błędzie nie wolno wysłać ANI JEDNEJ próbki")
        XCTAssertEqual(mic.flushCalls, 0)
        XCTAssertGreaterThan(mic.stopCalls, 0, "mikrofon musi zostać zamknięty")
        XCTAssertEqual(transport.count(of: "requestWindows"), 1, "nieaktualna lista musi zostać odświeżona")
        XCTAssertEqual(haptics.errors, 1)
    }

    func testFocusFailedRatujeTekstZamiastGoZgubic() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        transport.deliver(.started(target: "812:0"))
        await settle()
        session.endDictation()
        await settle()

        transport.deliver(.error(ErrorFrame(
            code: .focusFailed, message: "focus uciekł", target: "812:0",
            text: "napisz test do RemoteSession"
        )))
        await settle()

        XCTAssertEqual(session.phase, .failed(.wire(.focusFailed)))
        XCTAssertEqual(session.rescuedText, "napisz test do RemoteSession",
                       "wypowiedź nie może przepaść tylko dlatego, że focus uciekł")
        XCTAssertNil(session.lastInjected, "nic nie zostało wstrzyknięte — nie wolno udawać, że zostało")
    }

    func testBusyNieRozpoczynaDrugiejWypowiedzi() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        transport.deliver(.error(ErrorFrame(code: .busy, message: "zajęty")))
        await settle()

        XCTAssertEqual(session.phase, .failed(.wire(.busy)))
        XCTAssertEqual(mic.flushCalls, 0)
        XCTAssertTrue(transport.binary.isEmpty)
    }

    func testBrakZgodyNaMikrofonKonczySieCzytelnymBledem() async throws {
        await connectAndSelectDesktop()
        mic.failure = MicError.permissionDenied
        session.beginDictation(target: "812:0")
        await settle()

        guard case .failed(.mic) = session.phase else {
            return XCTFail("oczekiwano błędu mikrofonu, mamy \(session.phase)")
        }
        XCTAssertEqual(transport.count(of: "start"), 0, "bez mikrofonu nie ma po co zawracać głowy Macowi")
    }

    // MARK: - Timeouty

    func testMilczacyMacKonczySieTimeoutem_aNieWiszacymEkranem() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        XCTAssertEqual(session.phase, .arming(target: "812:0"))

        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(session.phase, .failed(.timeout))
        XCTAssertTrue(transport.binary.isEmpty)
        XCTAssertGreaterThan(mic.stopCalls, 0)
        XCTAssertEqual(transport.count(of: "cancel"), 1, "Mac musi wiedzieć, że przestaliśmy czekać")
    }

    func testSpoznioneStartedNieOtwieraStrumieniaIOdsylaCancel() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        try await Task.sleep(nanoseconds: 250_000_000)   // timeout mija
        transport.clearLog()

        transport.deliver(.started(target: "812:0"))
        await settle()

        XCTAssertEqual(mic.flushCalls, 0, "spóźniona zgoda nie może otworzyć strumienia")
        XCTAssertEqual(transport.count(of: "cancel"), 1,
                       "inaczej Mac zostaje z otwartą sesją i blokuje kolejne dyktowanie błędem `busy`")
    }

    func testBrakWynikuPoZakonczeniuNieWieszaEkranu() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        transport.deliver(.started(target: "812:0"))
        await settle()
        transport.deliver(.preview(text: "coś powiedziałem"))
        session.endDictation()
        await settle()

        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(session.phase, .failed(.timeout))
        XCTAssertEqual(session.rescuedText, "coś powiedziałem", "ostatni podgląd to wszystko, co zostało")
    }

    // MARK: - Zerwane połączenie

    func testZerwaniePolaczeniaWTrakcieMowieniaNieZostawiaWiszacegoStanu() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        transport.deliver(.started(target: "812:0"))
        await settle()

        transport.drop()
        await settle()

        XCTAssertEqual(session.phase, .failed(.disconnected))
        XCTAssertGreaterThan(mic.stopCalls, 0, "mikrofon nie może zostać otwarty po zerwaniu połączenia")
    }

    func testWejscieWTloAnulujeWypowiedz() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        transport.deliver(.started(target: "812:0"))
        await settle()

        session.enterBackground()
        await settle()

        XCTAssertEqual(transport.count(of: "cancel"), 1,
                       "bez `cancel` Mac zostaje z otwartą sesją, bo nigdy nie doczeka się `end`")
        XCTAssertEqual(session.phase, .ready)
    }

    // MARK: - Lista okien

    func testListaOkienJestSortowanaPoKolejnosciNakladania() async throws {
        await connectAndSelectDesktop()
        XCTAssertEqual(session.windows.map(\.id), ["812:0", "913:0"])
        XCTAssertEqual(session.generation, 42)
    }

    func testZnikniecieWybranegoOknaCzysciWyborIPodglad() async throws {
        await connectAndSelectDesktop()
        session.select(windowID: "812:0")
        transport.deliver(.terminal(TerminalFrame(id: "812:0", generation: 42, seq: 1, lines: ["a", "b"])))
        XCTAssertEqual(session.terminalLines.count, 2)

        transport.deliver(.windows(WindowsFrame(
            generation: 43, displays: [],
            windows: [WireWindow(id: "913:0", app: "Cursor", x: 0, y: 0, w: 10, h: 10)]
        )))
        await settle()

        XCTAssertNil(session.selectedWindowID)
        XCTAssertTrue(session.terminalLines.isEmpty, "podgląd zniknionego okna nie może zostać na ekranie")
    }

    func testPodgladTerminalaIgnorujeCudzeISpoznioneRamki() async throws {
        await connectAndSelectDesktop()
        session.select(windowID: "812:0")

        transport.deliver(.terminal(TerminalFrame(id: "812:0", generation: 42, seq: 5, lines: ["nowe"])))
        transport.deliver(.terminal(TerminalFrame(id: "812:0", generation: 42, seq: 3, lines: ["stare"])))
        transport.deliver(.terminal(TerminalFrame(id: "913:0", generation: 42, seq: 9, lines: ["cudze"])))

        XCTAssertEqual(session.terminalLines, ["nowe"],
                       "spóźniona i cudza ramka nie mogą podmienić treści pod palcem")
    }

    // MARK: - Zrzut ekranu

    func testBajtyObrazuBezNaglowkaSaOdrzucane() async throws {
        await connectAndSelectDesktop()
        transport.deliverBinary(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertNil(session.screenshotJPEG, "binarna ramka bez nagłówka to nie jest zrzut ekranu")

        transport.deliver(.screenshot(ScreenshotHeader(generation: 42, w: 100, h: 80, bytes: 3)))
        transport.deliverBinary(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(session.screenshotJPEG?.count, 3)
    }

    // MARK: - Subskrypcja

    func testSubskrypcjaWlaczaSieDopieroWZakladce() async throws {
        await connectAndSelectDesktop()

        session.setViewportActive(true)
        session.select(windowID: "812:0")
        await settle()
        guard case .subscribe(let active)? = transport.sent.last(where: { $0.type == "subscribe" }) else {
            return XCTFail("oczekiwano ramki subscribe")
        }
        XCTAssertTrue(active.windows)
        XCTAssertEqual(active.terminal, "812:0")

        session.setViewportActive(false)
        await settle()
        guard case .subscribe(let idle)? = transport.sent.last(where: { $0.type == "subscribe" }) else {
            return XCTFail("oczekiwano ramki subscribe")
        }
        XCTAssertFalse(idle.windows, "poza zakładką Mac nie ma po co niczego wysyłać")
        XCTAssertNil(idle.terminal)
    }

    func testPodgladTerminaluNieJestZamawianyDlaZwyklegoOkna() async throws {
        await connectAndSelectDesktop()
        session.setViewportActive(true)
        session.select(windowID: "913:0")   // Cursor, nie terminal
        await settle()

        guard case .subscribe(let frame)? = transport.sent.last(where: { $0.type == "subscribe" }) else {
            return XCTFail("oczekiwano ramki subscribe")
        }
        XCTAssertNil(frame.terminal)
    }

    // MARK: - Odporność

    func testNieznanaRamkaZMacaNiePsujeSesji() async throws {
        await connectAndSelectDesktop()
        transport.deliver(.unknown(type: "cosNowego"))
        await settle()
        XCTAssertEqual(session.phase, .ready)
    }

    func testDrugieDyktowanieWTrakcieTrwajacegoJestIgnorowane() async throws {
        await connectAndSelectDesktop()
        session.beginDictation(target: "812:0")
        await settle()
        transport.deliver(.started(target: "812:0"))
        await settle()
        transport.clearLog()

        session.beginDictation(target: "913:0")
        await settle()

        XCTAssertEqual(transport.count(of: "start"), 0, "jedna wypowiedź naraz — bez kolejkowania")
        XCTAssertEqual(session.phase, .streaming(target: "812:0"))
    }

    func testFocusOknaNiesieAktualnaGeneracje() async throws {
        await connectAndSelectDesktop()
        let window = try XCTUnwrap(session.windows.first)
        session.focus(window)
        XCTAssertEqual(transport.last, .focusWindow(id: "812:0", generation: 42))
    }
}

// MARK: - Parowanie i bufor

final class RemotePairingTests: XCTestCase {

    func testAdresRelayaDlaRoliPhone() throws {
        let url = try XCTUnwrap(RemotePairing.relayURL(
            RemoteCredentials(host: "relay.programo.pl", token: "abc")
        ))
        XCTAssertEqual(url.scheme, "wss", "bez schematu domyślnie szyfrowane — token leci przez ten kanał")
        XCTAssertEqual(url.path, "/ws")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("role=phone"))
        XCTAssertTrue(query.contains("token=abc"))
    }

    func testLokalnyAdresTestowyZachowujeSchemat() throws {
        let url = try XCTUnwrap(RemotePairing.relayURL(
            RemoteCredentials(host: "ws://127.0.0.1:8091", token: "t")
        ))
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.port, 8091)
    }

    func testPustePoswiadczeniaNieDajaAdresu() {
        XCTAssertNil(RemotePairing.relayURL(RemoteCredentials(host: "", token: "t")))
        XCTAssertNil(RemotePairing.relayURL(RemoteCredentials(host: "relay.pl", token: "")))
    }

    func testKodQRWObuFormatach() throws {
        let fromURL = try XCTUnwrap(RemotePairing.parseQR(
            "voiceflow-pair://pair?host=wss%3A%2F%2Frelay.programo.pl&token=sekret"
        ))
        XCTAssertEqual(fromURL.host, "wss://relay.programo.pl")
        XCTAssertEqual(fromURL.token, "sekret")

        let fromJSON = try XCTUnwrap(RemotePairing.parseQR(
            #"{"host":"wss://relay.programo.pl","token":"sekret"}"#
        ))
        XCTAssertEqual(fromJSON, fromURL)
    }

    /// Aparat widzi wszystkie kody QR w kadrze. Przypadkowy kod z paczki albo
    /// biletu nie może podmienić poświadczeń do zdalnego sterowania Makiem.
    func testObcyKodQRJestOdrzucany() {
        XCTAssertNil(RemotePairing.parseQR("https://programo.pl"))
        XCTAssertNil(RemotePairing.parseQR("WIFI:S:dom;T:WPA;P:haslo;;"))
        XCTAssertNil(RemotePairing.parseQR("voiceflow-pair://pair?host=relay.pl"))
        XCTAssertNil(RemotePairing.parseQR(#"{"host":"relay.pl"}"#))
        XCTAssertNil(RemotePairing.parseQR(""))
    }
}

final class PrebufferTests: XCTestCase {

    func testBuforOddajeCaloscICzysciSie() {
        var buffer = Prebuffer()
        buffer.append(Data([1, 2]))
        buffer.append(Data([3, 4]))
        XCTAssertEqual(buffer.drain(), Data([1, 2, 3, 4]))
        XCTAssertTrue(buffer.isEmpty, "drugie `drain` nie może wysłać tego samego dźwięku ponownie")
        XCTAssertEqual(buffer.drain(), Data())
    }

    /// Gdyby Mac milczał, bufor bez limitu rósłby w nieskończoność. Po
    /// przekroczeniu wypada NAJSTARSZY dźwięk — przy przeciągającym się czekaniu
    /// wartościowa jest końcówka wypowiedzi, nie jej początek.
    func testBuforMaTwardyLimitIGubiNAJSTARSZE() {
        var buffer = Prebuffer()
        let chunk = Data(repeating: 0xAB, count: 8192)
        for _ in 0..<20 { buffer.append(chunk) }

        XCTAssertLessThanOrEqual(buffer.count, Prebuffer.maxBytes)
        XCTAssertEqual(buffer.count, Prebuffer.maxBytes)
        XCTAssertEqual(Prebuffer.maxBytes, 64_000, "2 s przy 16 kHz Int16 mono")
    }
}
