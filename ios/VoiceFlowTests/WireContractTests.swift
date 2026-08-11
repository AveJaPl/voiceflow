import XCTest

/// Testy KONTRAKTU, nie implementacji. Dekodują te same pliki JSON
/// (`shared/wire/fixtures/`), które ma dekodować strona macOS — jeśli któraś
/// strona zmieni kształt ramki w pojedynkę, ten test zgaśnie tutaj, a nie na
/// żywym urządzeniu, gdzie objawem jest cisza i brak logu.
final class WireContractTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json"),
            "brak fixture'a \(name).json w bundle testowym — sprawdź `buildPhase: resources` w ios/project.yml"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Mac → telefon

    func testHelloNiesieZdolnosciMaca() throws {
        guard case .hello(let hello) = WireCodec.decodeMacFrame(try fixture("mac-hello")) else {
            return XCTFail("oczekiwano ramki hello")
        }
        XCTAssertEqual(hello.protocol, Wire.protocolVersion)
        XCTAssertEqual(hello.mac, "MacBook Wojtka")
        XCTAssertTrue(hello.caps.screenshot)
        XCTAssertTrue(hello.caps.terminalText)
        XCTAssertTrue(hello.caps.move)
    }

    func testWindowsNiesieGeometrieIRodzajOkna() throws {
        guard case .windows(let payload) = WireCodec.decodeMacFrame(try fixture("mac-windows")) else {
            return XCTFail("oczekiwano ramki windows")
        }
        XCTAssertEqual(payload.generation, 42)
        XCTAssertEqual(payload.displays.first?.w, 3456)
        XCTAssertEqual(payload.windows.count, 2)

        let terminal = try XCTUnwrap(payload.windows.first { $0.id == "812:0" })
        XCTAssertEqual(terminal.app, "Terminal")
        XCTAssertEqual(terminal.title, "claude — ~/Programo/voiceflow")
        XCTAssertTrue(terminal.isTerminal)
        XCTAssertTrue(terminal.focused)
        XCTAssertEqual(terminal.inject, .clipboard)
        XCTAssertEqual(terminal.w, 1728)

        let cursor = try XCTUnwrap(payload.windows.first { $0.id == "913:0" })
        XCTAssertFalse(cursor.isTerminal)
        XCTAssertFalse(cursor.focused)
    }

    /// Mac starszy niż telefon może nie przysłać pól, które doszły później.
    /// Brak pola NIE MOŻE wywalić całej listy okien — to jest cała różnica
    /// między „jedno okno bez tytułu" a „pusty ekran zamiast pulpitu".
    func testBrakujacePolaDostajaWartosciDomyslneZamiastWywalicRamke() throws {
        guard case .windows(let payload) = WireCodec.decodeMacFrame(try fixture("mac-windows-minimal")) else {
            return XCTFail("oczekiwano ramki windows")
        }
        let window = try XCTUnwrap(payload.windows.first)
        XCTAssertEqual(window.id, "1:0")
        XCTAssertNil(window.title)
        XCTAssertEqual(window.displayTitle, "Safari", "okno bez tytułu nie może być pustym wierszem na liście")
        XCTAssertEqual(window.kind, .other)
        XCTAssertEqual(window.inject, .clipboard)
        XCTAssertEqual(window.display, 1)
        XCTAssertFalse(window.focused)
    }

    func testScreenshotToSAMNAGLOWEK() throws {
        guard case .screenshot(let header) = WireCodec.decodeMacFrame(try fixture("mac-screenshot")) else {
            return XCTFail("oczekiwano nagłówka screenshot")
        }
        XCTAssertEqual(header.format, "jpeg")
        XCTAssertEqual(header.w, 1200)
        XCTAssertEqual(header.bytes, 81234)
    }

    func testTerminalNiesieLinieISekwencje() throws {
        guard case .terminal(let payload) = WireCodec.decodeMacFrame(try fixture("mac-terminal")) else {
            return XCTFail("oczekiwano ramki terminal")
        }
        XCTAssertEqual(payload.id, "812:0")
        XCTAssertEqual(payload.seq, 7)
        XCTAssertEqual(payload.lines.count, 2)
    }

    func testStartedPreviewInjected() throws {
        guard case .started(let target) = WireCodec.decodeMacFrame(try fixture("mac-started")) else {
            return XCTFail("oczekiwano ramki started")
        }
        XCTAssertEqual(target, "812:0")

        guard case .preview(let text) = WireCodec.decodeMacFrame(try fixture("mac-preview")) else {
            return XCTFail("oczekiwano ramki preview")
        }
        XCTAssertEqual(text, "napisz test do RemoteSession")

        guard case .injected(let injected) = WireCodec.decodeMacFrame(try fixture("mac-injected")) else {
            return XCTFail("oczekiwano ramki injected")
        }
        XCTAssertEqual(injected.via, .clipboard)
        XCTAssertEqual(injected.target, "812:0")
    }

    func testKodyBledow() throws {
        guard case .error(let gone) = WireCodec.decodeMacFrame(try fixture("mac-error-windowgone")) else {
            return XCTFail("oczekiwano ramki error")
        }
        XCTAssertEqual(gone.code, .windowGone)
        XCTAssertNil(gone.text)

        guard case .error(let rescued) = WireCodec.decodeMacFrame(try fixture("mac-error-focusfailed-rescued")) else {
            return XCTFail("oczekiwano ramki error")
        }
        XCTAssertEqual(rescued.code, .focusFailed)
        XCTAssertEqual(
            rescued.text, "napisz test do RemoteSession",
            "nieudane wstrzyknięcie musi ODDAĆ tekst, inaczej wypowiedź przepada"
        )
    }

    /// `mac_offline` produkuje RELAY, nie Mac (`relay/src/relayHub.js`). Apka musi
    /// go rozumieć, inaczej „Mac wyłączony" wygląda na telefonie jak cisza.
    func testBladZRelayaJestRozpoznawany() throws {
        guard case .error(let payload) = WireCodec.decodeMacFrame(try fixture("mac-error-relay-offline")) else {
            return XCTFail("oczekiwano ramki error")
        }
        XCTAssertEqual(payload.code, .macOffline)
    }

    /// Nowszy Mac przyśle kiedyś ramkę, której ta wersja apki nie zna. Ma ją
    /// zignorować, a nie zerwać sesję dyktowania.
    func testNieznanaRamkaNieWywracaDekodowania() throws {
        guard case .unknown(let type) = WireCodec.decodeMacFrame(try fixture("mac-unknown-future")) else {
            return XCTFail("oczekiwano .unknown")
        }
        XCTAssertEqual(type, "quantumTeleport")
    }

    func testSmiecNieWywracaDekodowania() {
        XCTAssertEqual(WireCodec.decodeMacFrame("to nie jest json"), .unknown(type: ""))
        XCTAssertEqual(WireCodec.decodeMacFrame(""), .unknown(type: ""))
        XCTAssertEqual(WireCodec.decodeMacFrame("{}"), .unknown(type: ""))
    }

    // MARK: - Telefon → Mac

    func testRamkiTelefonuDekodujaSieDoTegoSamego() throws {
        XCTAssertEqual(
            WireCodec.decodePhoneFrame(try fixture("phone-subscribe")),
            .subscribe(SubscribeFrame(windows: true, screenshot: true, terminal: "812:0"))
        )
        XCTAssertEqual(
            WireCodec.decodePhoneFrame(try fixture("phone-focuswindow")),
            .focusWindow(id: "812:0", generation: 42)
        )
        XCTAssertEqual(
            WireCodec.decodePhoneFrame(try fixture("phone-start")),
            .start(target: "812:0", generation: 42)
        )
        XCTAssertEqual(
            WireCodec.decodePhoneFrame(try fixture("phone-start-frontmost")),
            .start(target: nil, generation: nil),
            "start bez celu to zgodność wsteczna ze starszym Makiem — nie wolno jej zgubić"
        )
        XCTAssertEqual(
            WireCodec.decodePhoneFrame(try fixture("phone-movewindow")),
            .moveWindow(MoveFrame(id: "812:0", generation: 42, x: 1728, y: 0, w: 1728, h: 2234))
        )
        XCTAssertEqual(
            WireCodec.decodePhoneFrame(try fixture("phone-key-return")),
            .key(chord: .return_)
        )
    }

    /// To, co zakodujemy, musi się zdekodować do tego samego — inaczej Mac
    /// dostanie ramkę, której nie zrozumie, i po prostu nic nie zrobi.
    func testPelnyObiegKodowaniaRamekTelefonu() throws {
        let frames: [PhoneFrame] = [
            .hello(PhoneHello(device: "iPhone Wojtka")),
            .subscribe(SubscribeFrame(windows: true, screenshot: false, terminal: nil)),
            .unsubscribe, .requestWindows, .requestScreenshot,
            .focusWindow(id: "812:0", generation: 42),
            .moveWindow(MoveFrame(id: "812:0", generation: 42, x: 0, y: 0, w: 100, h: 200)),
            .start(target: "812:0", generation: 42),
            .start(target: nil, generation: nil),
            .end, .cancel,
            .key(chord: .ctrlC),
        ]
        for frame in frames {
            let text = try WireCodec.encodeToString(frame)
            XCTAssertEqual(WireCodec.decodePhoneFrame(text), frame, "obieg nie zamknął się dla \(frame.type)")
        }
    }

    func testPelnyObiegKodowaniaRamekMaca() throws {
        let frames: [MacFrame] = [
            .hello(MacHello(mac: "Mac", caps: MacCaps(screenshot: true, terminalText: false, move: true))),
            .windows(WindowsFrame(
                generation: 3,
                displays: [WireDisplay(id: 1, w: 100, h: 200, main: true)],
                windows: [WireWindow(id: "1:0", app: "Terminal", x: 0, y: 0, w: 10, h: 10, kind: .terminal)]
            )),
            .screenshot(ScreenshotHeader(generation: 3, w: 10, h: 10, bytes: 99)),
            .terminal(TerminalFrame(id: "1:0", generation: 3, seq: 1, lines: ["a"])),
            .started(target: "1:0"),
            .preview(text: "tekst"),
            .injected(InjectedFrame(target: "1:0", text: "tekst", via: .liveTyping)),
            .error(ErrorFrame(code: .busy, message: "zajęty")),
        ]
        for frame in frames {
            let text = try WireCodec.encodeToString(frame)
            XCTAssertEqual(WireCodec.decodeMacFrame(text), frame, "obieg nie zamknął się dla \(frame.type)")
        }
    }
}
