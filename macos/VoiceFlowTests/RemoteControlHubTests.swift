import XCTest
@testable import VoiceFlow

/// Scenariusze strony Maca zdalnego sterowania — te same, które apka iOS
/// przechodziła przeciw makiecie `tools/macsim`, tylko z drugiej strony drutu.
/// Wszystkie efekty uboczne za atrapami: zero prawdziwych okien, AX i sieci.
@MainActor
final class RemoteControlHubTests: XCTestCase {

    /// Atrapa zależności z pokrętłami per scenariusz + rejestr wysłanych ramek.
    @MainActor
    private final class Harness {
        var sentFrames: [MacFrame] = []
        var sentBinaries: [Data] = []
        var began = 0
        var ended = 0
        var cancelled = 0
        var pressedKeys: [KeyChord] = []
        /// Kolejne wywolania obwodki; `nil` = schowanie znacznika.
        var highlights: [String?] = []
        var spaceSteps: [Int] = []
        var spaceResult = true
        var focusResult = true
        var busy = false
        var snapshotGeneration = 1
        var windows: [WireWindow] = [
            WireWindow(id: "101", app: "Terminal", bundleID: "com.apple.Terminal",
                       title: "claude", x: 0, y: 0, w: 800, h: 600, kind: .terminal)
        ]
        var terminalLines: [String]? = ["$ claude", "> pracuję"]

        lazy var hub = RemoteControlHub(deps: .init(
            snapshotWindows: { [unowned self] in
                WindowsFrame(
                    generation: self.snapshotGeneration,
                    displays: [WireDisplay(id: 1, w: 1470, h: 956, main: true)],
                    windows: self.windows
                )
            },
            windowFor: { [unowned self] id, generation in
                guard generation == self.snapshotGeneration else { return nil }
                return self.windows.first { $0.id == id }
            },
            focusWindow: { [unowned self] _ in self.focusResult },
            moveWindow: { _, _ in true },
            terminalLines: { [unowned self] _ in self.terminalLines },
            screenshot: { nil },
            beginDictation: { [unowned self] in
                if self.busy { return false }
                self.began += 1
                return true
            },
            endDictation: { [unowned self] in self.ended += 1 },
            cancelDictation: { [unowned self] in self.cancelled += 1 },
            postKey: { [unowned self] chord in self.pressedKeys.append(chord); return true },
            switchSpace: { [unowned self] offset, _ in
                self.spaceSteps.append(offset)
                return self.spaceResult ? (index: 2, count: 3) : nil
            },
            highlightWindow: { [unowned self] window in self.highlights.append(window?.id) },
            sendFrame: { [unowned self] in self.sentFrames.append($0) },
            sendBinary: { [unowned self] in self.sentBinaries.append($0) },
            macName: "TestMac",
            capabilities: MacCaps(screenshot: false, terminalText: true, move: true)
        ))
    }

    func testHelloOdpowiadaHello() async {
        let harness = Harness()
        await harness.hub.handle(.hello(PhoneHello(device: "iPhone")))
        guard case .hello(let hello)? = harness.sentFrames.first else {
            return XCTFail("brak hello w odpowiedzi")
        }
        XCTAssertEqual(hello.mac, "TestMac")
        XCTAssertTrue(hello.caps.terminalText)
    }

    func testStartDoOknaWysylaStartedDopieroPoFokusie() async {
        let harness = Harness()
        await harness.hub.handle(.start(target: "101", generation: 1))
        XCTAssertEqual(harness.began, 1)
        guard case .started(let target)? = harness.sentFrames.last else {
            return XCTFail("brak started, ramki: \(harness.sentFrames)")
        }
        XCTAssertEqual(target, "101")
    }

    func testStartZeStaraGeneracjaToWindowGoneBezDyktowania() async {
        let harness = Harness()
        await harness.hub.handle(.start(target: "101", generation: 999))
        // Sesja została otwarta i NATYCHMIAST anulowana — mikrofon nie zostaje.
        XCTAssertEqual(harness.cancelled, 1)
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .windowGone)
    }

    func testNieudanyFokusToFocusFailedBezStarted() async {
        let harness = Harness()
        harness.focusResult = false
        await harness.hub.handle(.start(target: "101", generation: 1))
        XCTAssertEqual(harness.cancelled, 1)
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .focusFailed)
        XCTAssertFalse(harness.sentFrames.contains { if case .started = $0 { true } else { false } })
    }

    func testZajetaSesjaToBusy() async {
        let harness = Harness()
        harness.busy = true
        await harness.hub.handle(.start(target: "101", generation: 1))
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .busy)
    }

    func testStartBezCeluZachowujeStareZachowanie() async {
        let harness = Harness()
        await harness.hub.handle(.start(target: nil, generation: nil))
        XCTAssertEqual(harness.began, 1)
        guard case .started(let target)? = harness.sentFrames.last else {
            return XCTFail("brak started")
        }
        XCTAssertNil(target)
    }

    func testInjectedIdzieTylkoDlaZdalnegoCelu() async {
        let harness = Harness()
        // Lokalna wypowiedź (bez zdalnego celu) — cisza na drucie.
        harness.hub.dictationFinished(text: "lokalny tekst", injected: true)
        XCTAssertTrue(harness.sentFrames.isEmpty)

        // Zdalna wypowiedź do okna 101 — telefon dostaje potwierdzenie.
        await harness.hub.handle(.start(target: "101", generation: 1))
        harness.hub.dictationFinished(text: "zdalny tekst", injected: true)
        guard case .injected(let injected)? = harness.sentFrames.last else {
            return XCTFail("brak injected")
        }
        XCTAssertEqual(injected.text, "zdalny tekst")
        XCTAssertEqual(injected.target, "101")
    }

    func testNieudaneWstrzykniecieRatujeTekstWRamceError() async {
        let harness = Harness()
        await harness.hub.handle(.start(target: "101", generation: 1))
        harness.hub.dictationFinished(text: "uratowany tekst", injected: false)
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.text, "uratowany tekst")
    }

    func testSubskrypcjaTerminalaStrumieniujeZRosnacymSeq() async {
        let harness = Harness()
        await harness.hub.handle(.subscribe(SubscribeFrame(windows: false, screenshot: false, terminal: "101")))
        guard case .terminal(let frame)? = harness.sentFrames.last else {
            return XCTFail("brak ramki terminal, ramki: \(harness.sentFrames)")
        }
        XCTAssertEqual(frame.seq, 1)
        XCTAssertEqual(frame.lines, ["$ claude", "> pracuję"])
    }

    func testZrzutBezUprawnieniaToNotPermitted() async {
        let harness = Harness()
        await harness.hub.handle(.requestScreenshot)
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .notPermitted)
        XCTAssertTrue(harness.sentBinaries.isEmpty)
    }

    // MARK: - Pilot (klawisz z celem)

    /// ⌘V z pilota MUSI trafić w okno, które user widzi na telefonie — czyli
    /// najpierw podniesienie i weryfikacja, dopiero potem klawisz.
    func testKlawiszZCelemNajpierwPodnosiOkno() async {
        let harness = Harness()
        await harness.hub.handle(.key(chord: .cmdV, target: "101", generation: 1))
        XCTAssertEqual(harness.pressedKeys, [.cmdV])
    }

    /// Nieudany fokus = NIC nie zostało naciśnięte. Wciśnięcie ⌃C w losowym
    /// oknie tylko dlatego, że cel uciekł, byłoby gorsze niż brak funkcji.
    func testNieudanyFokusNieNaciskaKlawisza() async {
        let harness = Harness()
        harness.focusResult = false
        await harness.hub.handle(.key(chord: .ctrlC, target: "101", generation: 1))
        XCTAssertTrue(harness.pressedKeys.isEmpty)
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .focusFailed)
    }

    func testKlawiszDoZnikniętegoOknaZglaszaWindowGone() async {
        let harness = Harness()
        await harness.hub.handle(.key(chord: .return_, target: "101", generation: 99))
        XCTAssertTrue(harness.pressedKeys.isEmpty)
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .windowGone)
    }

    /// Zmiana pulpitu leci BEZ celu — podniesienie okna przerzuciłoby nas z
    /// powrotem na pulpit tego okna, czyli odwrotnie do zamiaru.
    func testZmianaPulpituNiePodnosiZadnegoOkna() async {
        let harness = Harness()
        await harness.hub.handle(.key(chord: .ctrlRight, target: nil, generation: nil))
        XCTAssertEqual(harness.pressedKeys, [.ctrlRight])
        XCTAssertTrue(harness.highlights.isEmpty)
    }

    /// Zgodność wsteczna: bez celu naciskamy na froncie, tak jak dotąd.
    func testKlawiszBezCeluNaciskaNaFroncie() async {
        let harness = Harness()
        harness.focusResult = false
        await harness.hub.handle(.key(chord: .return_, target: nil, generation: nil))
        XCTAssertEqual(harness.pressedKeys, [.return_])
    }

    // MARK: - Obwódka na ekranie Maca

    /// Pilot jest do sterowania Makiem, przy którym się SIEDZI — bez znacznika
    /// na ekranie „terminal 7/8" na telefonie nic nie znaczy.
    func testPrzeskokFokusuZaznaczaOknoNaEkranie() async {
        let harness = Harness()
        await harness.hub.handle(.focusWindow(id: "101", generation: 1))
        XCTAssertEqual(harness.highlights, ["101"])
    }

    func testNieudanyFokusNiczegoNieZaznacza() async {
        let harness = Harness()
        harness.focusResult = false
        await harness.hub.handle(.focusWindow(id: "101", generation: 1))
        XCTAssertTrue(harness.highlights.isEmpty)
    }

    /// Telefon wyszedł z zakładki — znacznik znika, zamiast zostawać na ekranie.
    func testWyjscieZPodgladuChowaZnacznik() async {
        let harness = Harness()
        await harness.hub.handle(.focusWindow(id: "101", generation: 1))
        await harness.hub.handle(.unsubscribe)
        XCTAssertEqual(harness.highlights, ["101", nil])
    }

    // MARK: - Pulpity

    /// Zmiana pulpitu idzie WŁASNĄ drogą (`SpaceSwitcher`), bo syntetyczne
    /// ⌃←/⌃→ WindowServer ignoruje — zmierzone na żywo 2026-08-14.
    func testZmianaPulpituNieIdziePrzezKlawiature() async {
        let harness = Harness()
        await harness.hub.handle(.space(offset: 1))
        XCTAssertEqual(harness.spaceSteps, [1])
        XCTAssertTrue(harness.pressedKeys.isEmpty)
        // Po zmianie pulpitu telefon dostaje świeżą listę okien bez pytania.
        let spaces = harness.sentFrames.compactMap { frame -> SpacesFrame? in
            if case .spaces(let payload) = frame { return payload } else { return nil }
        }.first
        guard let spaces else {
            return XCTFail("brak ramki spaces — telefon nie ma czym pokazać, że pulpit się zmienił")
        }
        XCTAssertEqual(spaces.index, 2)
        XCTAssertEqual(spaces.count, 3)
        // Po zmianie pulpitu lecą też świeże okna — inne są na wierzchu.
        XCTAssertTrue(harness.sentFrames.contains { if case .windows = $0 { true } else { false } })
    }

    /// Skrajny pulpit: telefon dostaje błąd zamiast ciszy, która wygląda
    /// identycznie jak zepsuty przycisk.
    func testSkrajnyPulpitZglaszaBlad() async {
        let harness = Harness()
        harness.spaceResult = false
        await harness.hub.handle(.space(offset: -1))
        guard case .error(let error)? = harness.sentFrames.last else {
            return XCTFail("brak ramki error")
        }
        XCTAssertEqual(error.code, .unsupported)
    }

    /// Każdy akord pilota musi mieć mapowanie na kod klawisza — inaczej Mac
    /// odpowiada „unsupported", a przycisk na telefonie jest atrapą.
    func testWszystkieAkordyPilotaMajaMapowanie() {
        for chord: KeyChord in [.return_, .escape, .cmdReturn, .ctrlC, .cmdZ, .cmdV, .ctrlU, .ctrlLeft, .ctrlRight] {
            XCTAssertNotNil(KeyChordSender.mapping(for: chord), "brak mapowania dla \(chord.rawValue)")
        }
        XCTAssertNil(KeyChordSender.mapping(for: KeyChord(rawValue: "cmdShiftQ")))
    }
}
