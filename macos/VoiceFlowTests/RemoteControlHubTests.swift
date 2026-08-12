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
            postKey: { _ in true },
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
}
