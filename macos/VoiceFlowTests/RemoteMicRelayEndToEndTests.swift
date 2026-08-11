import XCTest
import AVFoundation
@testable import VoiceFlow

private final class InMemoryTokenStore: PairingTokenStoring {
    private var token: String?
    init(token: String) { self.token = token }
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken() { token = nil }
}

/// Kryterium #3 zadania (docs/plans/remote-mic-relay.md): test end-to-end
/// BEZ TELEFONU. Prawdziwy `RemoteMicClient` (rola "mac") i prawdziwy
/// `URLSessionWebSocketTask` udający telefon (rola "phone") łączą się z
/// LOKALNIE uruchomionym relayem (`services/relay`) przez prawdziwą sieć
/// (loopback) — dokładnie ten sam wzorzec weryfikacji co
/// `WhisperSpeechEngineTests.testSessionControllerAppliesFinalTextFromWav`
/// (realny plik WAV, realny `SessionController`, log `[Inject] final … OK`
/// w `voiceflow.log`), tylko że audio wchodzi przez relay zamiast przez
/// `AudioCapture.onBuffer` bezpośrednio.
///
/// CELOWO wyłączony z normalnego `xcodebuild test` (patrz `XCTSkip` niżej) —
/// wymaga osobno uruchomionego procesu `services/relay` i jest siecowy,
/// więc nie może być częścią standardowego, zawsze-zielonego zestawu 47
/// testów jednostkowych. Instrukcja odpalenia — patrz raport zadania
/// remote-mic-relay (sekcja "jak main session ma odtworzyć test e2e").
final class RemoteMicRelayEndToEndTests: XCTestCase {
    /// Konfiguracja przez PLIK, nie zmienne środowiskowe — `xcodebuild test`
    /// uruchamia hosta testów przez LaunchServices (widać w logu
    /// `RegisterWithLaunchServices`), który NIE dziedziczy środowiska
    /// powłoki wywołującej `xcodebuild` (zmierzone: `TEST_RUNNER_*` też nie
    /// przechodzi mimo że xcodebuild je rozpoznaje jako build setting).
    /// Plik na dysku omija ten problem: dowolny proces go widzi tak samo.
    private static let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voiceflow-e2e-relay-config.json")

    struct Config: Decodable {
        let url: String
        let token: String
    }

    @MainActor
    func testRealRelayDeliversRemoteAudioToInjectedText() async throws {
        guard let configData = try? Data(contentsOf: Self.configURL),
              let config = try? JSONDecoder().decode(Config.self, from: configData) else {
            throw XCTSkip(
                "Brak \(Self.configURL.path) — pomijam test sieciowy end-to-end. Uruchom "
                    + "lokalnie services/relay i sparuj (patrz raport zadania remote-mic-relay), "
                    + "potem zapisz {\"url\":\"ws://127.0.0.1:PORT\",\"token\":\"...\"} pod tą ścieżką."
            )
        }
        let relayURL = config.url
        let token = config.token

        let engine = WhisperSpeechEngine(language: "pl")
        let audioCapture = AudioCapture()
        let tmpNotesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-e2e-notes-\(UUID().uuidString).json")
        let controller = SessionController(
            audioCapture: audioCapture,
            engine: engine,
            notesStore: NotesStore(fileURL: tmpNotesURL)
        )
        await controller.prewarm()

        let defaults = UserDefaults(suiteName: "RemoteMicRelayE2E.\(UUID().uuidString)")!
        defaults.set(true, forKey: SettingsKeys.remoteMicEnabled)
        defaults.set(relayURL, forKey: SettingsKeys.remoteMicHost)

        let client = RemoteMicClient(
            sessionController: controller,
            audioCapture: audioCapture,
            tokenStore: InMemoryTokenStore(token: token),
            defaults: defaults
        )
        client.start()

        let connectDeadline = Date().addingTimeInterval(10)
        while client.connectionState != .connected, Date() < connectDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(client.connectionState, .connected, "RemoteMicClient nie połączył się z relayem — czy jest uruchomiony na \(relayURL)?")

        // Symulacja telefonu: OSOBNE połączenie WS, rola "phone", DOKŁADNIE
        // ta sekwencja ramek, którą wyśle realna apka iOS (§ kontrakt w
        // doc-comment RemoteMicClient.swift) — start, WAV pocięty na kawałki
        // w tempie rzeczywistym jako Int16 16kHz mono, end.
        guard var components = URLComponents(string: relayURL) else {
            XCTFail("nieprawidłowy VOICEFLOW_E2E_RELAY_URL: \(relayURL)")
            return
        }
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "phone"),
            URLQueryItem(name: "token", value: token),
        ]
        let phoneTask = URLSession.shared.webSocketTask(with: components.url!)
        phoneTask.resume()

        try await phoneTask.send(.string(#"{"type":"start"}"#))

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dyktowanie-pl.wav")
        let file = try AVAudioFile(forReading: fixtureURL, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let full = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("nie udało się zaalokować bufora fixture")
        }
        try file.read(into: full)
        guard let channelData = full.int16ChannelData else {
            XCTFail("fixture nie jest Int16 po wymuszeniu commonFormat")
            return
        }

        let sampleRate = file.fileFormat.sampleRate
        let chunkFrames = 1600 // ~100 ms przy 16 kHz — realistyczny rozmiar ramki sieciowej
        var offset = 0
        let totalFrames = Int(full.frameLength)
        while offset < totalFrames {
            let length = min(chunkFrames, totalFrames - offset)
            let data = Data(bytes: channelData[0] + offset, count: length * MemoryLayout<Int16>.size)
            try await phoneTask.send(.data(data))
            try await Task.sleep(nanoseconds: UInt64(Double(length) / sampleRate * 1_000_000_000))
            offset += length
        }
        // Łaska po ostatnim kawałku — patrz komentarz w WhisperSpeechEngineTests,
        // ten sam powód (dekodowanie co ~300ms, ostatni krok potrzebuje chwili).
        try await Task.sleep(nanoseconds: 700_000_000)
        try await phoneTask.send(.string(#"{"type":"end"}"#))
        try await Task.sleep(nanoseconds: 500_000_000)

        phoneTask.cancel(with: .goingAway, reason: nil)
        client.stop()
        try? FileManager.default.removeItem(at: tmpNotesURL)

        // Dowód kryterium #3: prawdziwy log pliku, ta sama ścieżka weryfikacji
        // co whisper e2e (docs/plans/whisper-local-engine-pl.md).
        let logContent = (try? String(contentsOf: DebugLog.url, encoding: .utf8)) ?? ""
        let lastInjectLine = logContent.split(separator: "\n").last { $0.contains("[Inject] final") }
        XCTAssertNotNil(lastInjectLine, "brak wpisu [Inject] final w voiceflow.log po zdalnym dyktowaniu")
        if let lastInjectLine {
            print("RemoteMicRelayEndToEndTests: \(lastInjectLine)")
            XCTAssertTrue(lastInjectLine.contains("OK"), "ostatni [Inject] final nie zakończył się OK: \(lastInjectLine)")
        }
    }
}
