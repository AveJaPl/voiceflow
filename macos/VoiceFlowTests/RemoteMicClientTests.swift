import XCTest
import AVFoundation
@testable import VoiceFlow

/// Silnik-atrapa: rejestruje wywołania `beginUtterance`/`feed`/`endUtterance`
/// bez ładowania prawdziwego modelu whisper.cpp — testy niżej weryfikują
/// WYŁĄCZNIE tłumaczenie ramek WS na te wywołania (kryterium zadania), nie
/// jakość ASR (to już pokrywa `WhisperSpeechEngineTests`).
private final class RecordingSpeechEngine: SpeechEngine {
    let updates: AsyncStream<TranscriptUpdate>
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation!
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var fedBuffers: [AVAudioPCMBuffer] = []

    init() {
        var cont: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func prewarm() async throws {}
    func beginUtterance() { beginCount += 1 }
    func endUtterance() { endCount += 1 }
    func feed(_ buffer: AVAudioPCMBuffer) { fedBuffers.append(buffer) }
}

private final class RecordingInjector: TextInjecting, ClipboardInjecting {
    private(set) var applyPlans: [InjectionPlan] = []
    private(set) var clipboardTexts: [String] = []
    func apply(_ plan: InjectionPlan) throws { applyPlans.append(plan) }
    func insertViaClipboard(_ text: String) throws { clipboardTexts.append(text) }
}

private final class NoOpDucking: AudioDucking {
    func start() {}
    func stop() {}
}
private final class NoOpDiscordMute: DiscordMuteToggling {
    func start() {}
    func stop() {}
}

/// Socket-atrapa: kolejka wiadomości do zwrócenia przez `receive()`; po
/// wyczerpaniu rzuca błąd (kończy pętlę odbioru w `RemoteMicClient`, dokładnie
/// jak zerwane połączenie) — zero prawdziwej sieci, zgodnie z kryterium
/// zadania "mockuj WebSocket, nie łącz się z prawdziwym relayem".
private final class FakeRemoteMicSocket: RemoteMicSocket {
    private var messages: [URLSessionWebSocketTask.Message]
    private var index = 0
    private(set) var sent: [URLSessionWebSocketTask.Message] = []
    private(set) var resumed = false
    private(set) var cancelled = false

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.messages = messages
    }

    func resume() { resumed = true }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sent.append(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard index < messages.count else { throw URLError(.cancelled) }
        defer { index += 1 }
        return messages[index]
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
    }
}

private final class FakeTokenStore: PairingTokenStoring {
    var token: String?
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken() { token = nil }
}

@MainActor
final class RemoteMicClientTests: XCTestCase {
    private func makeSessionController(
        engine: RecordingSpeechEngine, audioCapture: AudioCapture, injector: RecordingInjector
    ) -> SessionController {
        let tmpNotesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-remote-mic-test-\(UUID().uuidString).json")
        return SessionController(
            audioCapture: audioCapture,
            engine: engine,
            injector: injector,
            notesStore: NotesStore(fileURL: tmpNotesURL),
            audioDucker: NoOpDucking(),
            discordMuteToggle: NoOpDiscordMute()
        )
    }

    private func pcmData(sampleCount: Int) -> Data {
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount { samples[i] = Int16(clamping: i * 37) }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func makeDefaults(enabled: Bool, host: String = "ws://127.0.0.1:9") -> UserDefaults {
        let defaults = UserDefaults(suiteName: "RemoteMicClientTests.\(UUID().uuidString)")!
        defaults.set(enabled, forKey: SettingsKeys.remoteMicEnabled)
        defaults.set(host, forKey: SettingsKeys.remoteMicHost)
        return defaults
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
    }

    /// Kryterium główne: `start` -> `audio` × N -> `end` z relaya tłumaczy się
    /// DOKŁADNIE na `SessionController.beginUtterance()`/`feed()`/
    /// `endUtterance()`, plus wysyłkę focusu przy starcie (§5a planu).
    @MainActor
    func testStartAudioEndTranslatesToSessionControllerCalls() async throws {
        let engine = RecordingSpeechEngine()
        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        let injector = RecordingInjector()
        let controller = makeSessionController(engine: engine, audioCapture: audioCapture, injector: injector)
        await controller.prewarm()

        let tokenStore = FakeTokenStore()
        tokenStore.token = "test-token"
        let audioData = pcmData(sampleCount: 160)
        let socket = FakeRemoteMicSocket(messages: [
            .string(#"{"type":"start"}"#),
            .data(audioData),
            .data(audioData),
            .string(#"{"type":"end"}"#),
        ])

        let client = RemoteMicClient(
            sessionController: controller,
            audioCapture: audioCapture,
            tokenStore: tokenStore,
            defaults: makeDefaults(enabled: true),
            socketFactory: { _ in socket }
        )
        client.start()
        await waitUntil { engine.endCount > 0 }
        client.stop()

        XCTAssertTrue(socket.resumed)
        XCTAssertEqual(engine.beginCount, 1)
        XCTAssertEqual(engine.endCount, 1)
        XCTAssertEqual(engine.fedBuffers.count, 2)
        XCTAssertEqual(engine.fedBuffers.first?.frameLength, 160)
        XCTAssertTrue(
            socket.sent.contains { message in
                if case .string(let text) = message { return text.contains(#""type":"focus""#) }
                return false
            },
            "\"start\" powinien wywołać wysyłkę bieżącego focusu (§5a planu)"
        )
    }

    /// Ramka audio poza oknem start/end (np. spóźniona po `end`, albo zanim
    /// telefon w ogóle wysłał `start`) NIE MOŻE trafić do silnika ASR.
    @MainActor
    func testAudioFrameBeforeStartIsIgnored() async throws {
        let engine = RecordingSpeechEngine()
        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        let injector = RecordingInjector()
        let controller = makeSessionController(engine: engine, audioCapture: audioCapture, injector: injector)
        await controller.prewarm()

        let tokenStore = FakeTokenStore()
        tokenStore.token = "test-token"
        let socket = FakeRemoteMicSocket(messages: [.data(pcmData(sampleCount: 80))])
        let client = RemoteMicClient(
            sessionController: controller,
            audioCapture: audioCapture,
            tokenStore: tokenStore,
            defaults: makeDefaults(enabled: true),
            socketFactory: { _ in socket }
        )
        client.start()
        await waitUntil(timeout: 0.5) { false } // daje pętli odbioru szansę przetworzyć jedyną ramkę
        client.stop()

        XCTAssertEqual(engine.fedBuffers.count, 0, "audio przed \"start\" musi być zignorowane")
        XCTAssertEqual(engine.beginCount, 0)
    }

    /// Niesparsowalna/nieznana ramka tekstowa nie wywala klienta ani sesji.
    @MainActor
    func testMalformedControlFrameDoesNotCrashOrStartSession() async throws {
        let engine = RecordingSpeechEngine()
        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        let injector = RecordingInjector()
        let controller = makeSessionController(engine: engine, audioCapture: audioCapture, injector: injector)
        await controller.prewarm()

        let tokenStore = FakeTokenStore()
        tokenStore.token = "test-token"
        let socket = FakeRemoteMicSocket(messages: [
            .string("nie jestem jsonem"),
            .string(#"{"typo":"start"}"#),
            .string(#"{"type":"nieznany"}"#),
        ])
        let client = RemoteMicClient(
            sessionController: controller,
            audioCapture: audioCapture,
            tokenStore: tokenStore,
            defaults: makeDefaults(enabled: true),
            socketFactory: { _ in socket }
        )
        client.start()
        await waitUntil(timeout: 0.5) { false }
        client.stop()

        XCTAssertEqual(engine.beginCount, 0)
    }

    /// Toggle wyłączony (domyślny stan, §zadanie: "domyślnie WYŁĄCZONE") — nie
    /// łączy się z relayem w ogóle, nawet jeśli token parowania istnieje.
    @MainActor
    func testDoesNotConnectWhenDisabled() async throws {
        let engine = RecordingSpeechEngine()
        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        let injector = RecordingInjector()
        let controller = makeSessionController(engine: engine, audioCapture: audioCapture, injector: injector)
        await controller.prewarm()

        let tokenStore = FakeTokenStore()
        tokenStore.token = "test-token"
        let socket = FakeRemoteMicSocket(messages: [.string(#"{"type":"start"}"#)])
        let client = RemoteMicClient(
            sessionController: controller,
            audioCapture: audioCapture,
            tokenStore: tokenStore,
            defaults: makeDefaults(enabled: false),
            socketFactory: { _ in socket }
        )
        client.start()
        await waitUntil(timeout: 0.3) { false }

        XCTAssertFalse(socket.resumed, "wyłączona funkcja nie powinna w ogóle łączyć się z relayem")
        XCTAssertEqual(client.connectionState, .disabled)
        client.stop()
    }

    /// Zdalna wypowiedź w trakcie, gdy lokalny skrót (ten sam `SessionController`)
    /// jest już `.listening` — start zdalny musi być cicho ignorowany, nie
    /// psuć trwającej lokalnej sesji (kryterium #4 zadania: obie ścieżki
    /// współistnieją, jedna sesja na raz).
    @MainActor
    func testRemoteStartIgnoredWhileLocalSessionIsListening() async throws {
        let engine = RecordingSpeechEngine()
        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        let injector = RecordingInjector()
        let controller = makeSessionController(engine: engine, audioCapture: audioCapture, injector: injector)
        await controller.prewarm()
        controller.beginUtterance() // symuluje lokalny skrót już wciśnięty
        XCTAssertEqual(controller.state, .listening)

        let tokenStore = FakeTokenStore()
        tokenStore.token = "test-token"
        let socket = FakeRemoteMicSocket(messages: [.string(#"{"type":"start"}"#)])
        let client = RemoteMicClient(
            sessionController: controller,
            audioCapture: audioCapture,
            tokenStore: tokenStore,
            defaults: makeDefaults(enabled: true),
            socketFactory: { _ in socket }
        )
        client.start()
        await waitUntil(timeout: 0.5) { false }
        client.stop()

        // `beginCount` == 1 to TYLKO lokalny `beginUtterance()` wołany wyżej —
        // zdalny start nie doszedł do skutku, bo stan nie był idle/done.
        XCTAssertEqual(engine.beginCount, 1)
        XCTAssertEqual(controller.state, .listening, "lokalna sesja nie może zostać przerwana przez ignorowany zdalny start")
    }
}
