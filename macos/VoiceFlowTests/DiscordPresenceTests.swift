import XCTest
@testable import VoiceFlow

/// Kryterium #3 zadania: DiscordPresence (start/stop, no-op gdy brak
/// socketu). Środowisko testowe/CI nie ma uruchomionego Discorda pod żadną
/// ze znanych ścieżek (`DiscordPresence.candidateSocketPaths`), więc
/// `socketFD` musi zostać `nil` deterministycznie — to JEST kryterium
/// "cichy no-op", nie tylko brak crasha.
final class DiscordPresenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "voiceflow-discordpresence-test-\(UUID().uuidString)")!
    }

    func testDisabledIsNoOp() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "voiceflow.discordPresenceEnabled")
        defaults.set("123456789", forKey: "voiceflow.discordPresenceClientID")
        let presence = DiscordPresence(defaults: defaults)

        presence.start()
        presence.queue.sync {} // odczekaj na ewentualną pracę w tle (nie powinno jej być)

        XCTAssertNil(presence.socketFD, "wyłączone w Ustawieniach — start() nie może niczego otworzyć")
    }

    func testEmptyClientIDIsNoOp() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "voiceflow.discordPresenceEnabled")
        // brak client ID
        let presence = DiscordPresence(defaults: defaults)

        presence.start()
        presence.queue.sync {}

        XCTAssertNil(presence.socketFD, "brak client ID — start() musi być no-op")
    }

    func testStartWithNoDiscordSocketRunningIsSilentNoOp() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "voiceflow.discordPresenceEnabled")
        defaults.set("123456789", forKey: "voiceflow.discordPresenceClientID")
        let presence = DiscordPresence(defaults: defaults)

        presence.start()
        presence.queue.sync {} // drenuje kolejkę — start() jest asynchroniczny

        XCTAssertNil(presence.socketFD, "brak realnego Discorda w środowisku testowym — cichy no-op, zero crasha")

        // stop() bez wcześniejszego udanego start() też musi być bezpieczny.
        presence.stop()
        presence.queue.sync {}
        XCTAssertNil(presence.socketFD)
    }

    func testEncodeFrameHeaderIsLittleEndianOpcodeAndLength() throws {
        let json: [String: Any] = ["v": 1, "client_id": "abc"]
        let data = try XCTUnwrap(DiscordPresence.encodeFrame(opcode: 0, json: json))
        XCTAssertGreaterThanOrEqual(data.count, 8)

        let opcode = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let length = data.dropFirst(4).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        XCTAssertEqual(opcode, 0)
        XCTAssertEqual(Int(length), data.count - 8)

        let payload = Data(data.dropFirst(8))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(decoded["client_id"] as? String, "abc")
        XCTAssertEqual(decoded["v"] as? Int, 1)
    }
}
