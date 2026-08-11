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

    func testCudzeDyktowanieBlokujeIPodajeImie() {
        let (client, transport, _) = makeClient()

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

        let result = client.mayStart()
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedBy, "Filip")
    }

    func testZdalnyMowiacySciszaDzwiekACiszaGoPrzywraca() {
        let (_, transport, ducked) = makeClient()

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])
        transport.deliver(["type": "speaker_changed", "speaking": NSNull()])

        XCTAssertEqual(ducked(), ["Filip", "<cisza>"])
    }

    func testPowtorzonyStanNieSciszaDwaRazy() {
        // Drugie ściszenie zapamiętałoby już ściszony poziom jako oryginalny
        // i zostawiło tę maszynę cicho na stałe.
        let (_, transport, ducked) = makeClient()

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])
        transport.deliver(["type": "room_state", "speaking": ["name": "Filip"]])

        XCTAssertEqual(ducked(), ["Filip"])
    }

    func testSciszanieMoznaWylaczycLokalnieAleBlokadaZostaje() {
        let (client, transport, ducked) = makeClient(duckForOthers: false)

        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

        XCTAssertEqual(ducked(), [])
        XCTAssertFalse(client.mayStart().allowed, "blokada działa niezależnie od ściszania")
    }

    func testUtrataPolaczeniaOdblokowuje() {
        // Pokój, którego nie widzimy, nie może nas blokować.
        let (client, transport, _) = makeClient()
        transport.deliver(["type": "speaker_changed", "speaking": ["name": "Filip"]])

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
