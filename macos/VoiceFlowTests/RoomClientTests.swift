import XCTest
@testable import VoiceFlow

/// Reguły pokoju po stronie macOS muszą być identyczne z pythonowymi — obie
/// platformy rozmawiają z tym samym serwerem, więc „kto może teraz mówić" nie
/// może zależeć od tego, na czym kto siedzi. Odpowiednik: tests/test_room.py.
@MainActor
final class RoomClientTests: XCTestCase {

    final class FakeTransport: RoomTransport {
        var sent: [[String: Any]] = []
        private var callback: (([String: Any]) -> Void)?

        func send(_ payload: [String: Any]) { sent.append(payload) }
        func onMessage(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
        func deliver(_ payload: [String: Any]) { callback?(payload) }
    }

    /// `RoomClient.handle` jest wołane przez `Task { @MainActor in … }`, bo prawdziwy
    /// transport (`RoomLink`) dostarcza ramki ze swojej własnej kolejki. Test musi
    /// więc oddać sterowanie, zanim cokolwiek sprawdzi — asercja tuż po `deliver()`
    /// biegnie ZANIM klient zobaczy ramkę.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func makeClient(
        duckForOthers: Bool = true,
        enabled: Bool = true
    ) -> (RoomClient, FakeTransport, () -> [String]) {
        let transport = FakeTransport()
        var ducked: [String] = []
        let config = RoomConfiguration(
            enabled: enabled, server: "wss://example", code: "ROOM01",
            token: "tok", duckForOthers: duckForOthers
        )
        let client = RoomClient(
            config: config,
            onRemoteSpeaking: { ducked.append($0) },
            onRemoteSilence: { ducked.append("<cisza>") },
            transport: transport
        )
        return (client, transport, { ducked })
    }

    func testWolnyPokojPozwalaDyktowac() {
        let (client, _, _) = makeClient()

        XCTAssertTrue(client.mayStart().allowed)
    }

    func testBlokadaBezSwiezegoPulsuWygasa() async {
        let (client, transport, _) = makeClient()
        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Jakub"]])
        await settle()
        XCTAssertFalse(client.mayStart().allowed)
        // Cofamy potwierdzenie poza termin ważności — jak przy zawieszonym
        // kliencie, który trzyma serwerową blokadę, ale nie pulsuje.
        client.expireSpeakerConfirmationForTests()
        XCTAssertTrue(client.mayStart().allowed, "przeterminowana blokada nie może więzić lokalnego dyktowania")
        withExtendedLifetime(client) {}
    }

    func testOdmowaSerweraNieOdswiezaTerminuBlokady() async {
        let (client, transport, _) = makeClient()
        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Jakub"]])
        await settle()
        client.expireSpeakerConfirmationForTests()
        // Odmowa przy próbie startu — z potencjalnie zawieszonej blokady —
        // nie jest dowodem, że mówiący żyje.
        transport.deliver(["type": "speaking_denied", "blockedBy": "Jakub"])
        await settle()
        XCTAssertTrue(client.mayStart().allowed, "odmowa nie może przedłużać przeterminowanej blokady")
        withExtendedLifetime(client) {}
    }

    func testCudzeDyktowanieBlokujeIPodajeImie() async {
        let (client, transport, _) = makeClient()

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

        await settle()

        let result = client.mayStart()
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedBy, "Filip")
    }

    func testZdalnyMowiacySciszaDzwiekACiszaGoPrzywraca() async {
        // `client` MUSI zostać przypisany: pod `_` zwalnia się natychmiast, a wtedy
        // `[weak self]` w callbacku transportu jest nil i ramka nie ma do kogo dotrzeć.
        let (client, transport, ducked) = makeClient()

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

        await settle()
        transport.deliver(["type": "speaker_changed", "speaking": NSNull()])
        await settle()

        XCTAssertEqual(ducked(), ["Filip", "<cisza>"])
        withExtendedLifetime(client) {}
    }

    func testPowtorzonyStanNieSciszaDwaRazy() async {
        // Drugie ściszenie zapamiętałoby już ściszony poziom jako oryginalny
        // i zostawiło tę maszynę cicho na stałe.
        let (client, transport, ducked) = makeClient()

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

        await settle()
        transport.deliver(["type": "room_state", "speaking": ["name": "Filip"]])

        XCTAssertEqual(ducked(), ["Filip"])
        withExtendedLifetime(client) {}
    }

    func testSciszanieMoznaWylaczycLokalnieAleBlokadaZostaje() async {
        let (client, transport, ducked) = makeClient(duckForOthers: false)

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

        await settle()

        XCTAssertEqual(ducked(), [])
        XCTAssertFalse(client.mayStart().allowed, "blokada działa niezależnie od ściszania")
    }

    func testUtrataPolaczeniaOdblokowuje() async {
        // Pokój, którego nie widzimy, nie może nas blokować.
        let (client, transport, _) = makeClient()
        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])
        await settle()

        client.onDisconnected()

        XCTAssertTrue(client.mayStart().allowed)
    }

    func testWysylamyWylacznieLiczby() {
        let (client, transport, _) = makeClient()

        client.reportStarted()
        client.reportFinished(words: 12, seconds: 4.25)

        XCTAssertEqual(transport.sent.first?["type"] as? String, "speaking_started")
        XCTAssertEqual(transport.sent.last?["words"] as? Int, 12)
        for payload in transport.sent {
            XCTAssertNil(payload["text"], "treść dyktowania nigdy nie opuszcza urządzenia")
        }
    }

    func testAnulowanieZwalniaPokojZerowymiLiczbami() {
        let (client, transport, _) = makeClient()

        client.reportCancelled()

        XCTAssertEqual(transport.sent.last?["type"] as? String, "speaking_ended")
        XCTAssertEqual(transport.sent.last?["words"] as? Int, 0)
    }

    func testWylaczonyPokojNigdyNieBlokujeIMilczy() {
        let (client, transport, _) = makeClient(enabled: false)

        client.reportStarted()

        XCTAssertTrue(client.mayStart().allowed)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAdresRestJestWyprowadzanyZAdresuWebSocketu() throws {
        XCTAssertEqual(try RoomJoiner.httpBase("wss://rooms.pbdevs.com"), "https://rooms.pbdevs.com")
        XCTAssertEqual(try RoomJoiner.httpBase("ws://localhost:3000/"), "http://localhost:3000")
        XCTAssertThrowsError(try RoomJoiner.httpBase("nie-adres"))
    }
}
