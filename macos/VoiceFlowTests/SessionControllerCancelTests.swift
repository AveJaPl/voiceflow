import XCTest
import AVFoundation
@testable import VoiceFlow

/// Silnik ASR minimalny — nie wywołuje żadnej realnej transkrypcji, tylko
/// liczy wywołania `beginUtterance`/`endUtterance`, żeby testy Escape/cancel
/// nie musiały ładować żadnego modelu (whisper.cpp/Apple).
private final class NoOpSpeechEngine: SpeechEngine {
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation!
    let updates: AsyncStream<TranscriptUpdate>
    private(set) var beginCount = 0
    private(set) var endCount = 0

    init() {
        var cont: AsyncStream<TranscriptUpdate>.Continuation!
        self.updates = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func prewarm() async throws {}
    func beginUtterance() { beginCount += 1 }
    func endUtterance() { endCount += 1 }
    func feed(_ buffer: AVAudioPCMBuffer) {}
}

private final class RecordingInjector: TextInjecting, ClipboardInjecting {
    private(set) var applyPlans: [InjectionPlan] = []
    private(set) var clipboardTexts: [String] = []
    func apply(_ plan: InjectionPlan) throws { applyPlans.append(plan) }
    func insertViaClipboard(_ text: String) throws { clipboardTexts.append(text) }
}

private final class CountingDucking: AudioDucking {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

private final class CountingDiscordMute: DiscordMuteToggling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

/// Kryterium #2 zadania (Escape = anulowanie dyktowania bez wklejania):
/// `.listening` -> `cancelUtterance()` -> `.idle`, ZERO `applyFinal`, ducking
/// cofnięty — analogicznie do istniejących testów `DictationDuckingTests`
/// i `WhisperSpeechEngineTests` (audio zastąpione hakiem testowym, żaden
/// prawdziwy mikrofon/model).
@MainActor
final class SessionControllerCancelTests: XCTestCase {
    private func makeController() -> (SessionController, NoOpSpeechEngine, RecordingInjector, CountingDucking, CountingDiscordMute) {
        let engine = NoOpSpeechEngine()
        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        let injector = RecordingInjector()
        let ducker = CountingDucking()
        let discordMute = CountingDiscordMute()
        let tmpNotesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-test-notes-\(UUID().uuidString).json")
        let controller = SessionController(
            audioCapture: audioCapture,
            engine: engine,
            injector: injector,
            notesStore: NotesStore(fileURL: tmpNotesURL),
            audioDucker: ducker,
            discordMuteToggle: discordMute
        )
        return (controller, engine, injector, ducker, discordMute)
    }

    func testCancelUtteranceDuringListeningSkipsInjectionAndReturnsToIdle() async throws {
        let (controller, engine, injector, ducker, discordMute) = makeController()

        controller.beginUtterance()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(ducker.startCount, 1, "ducking musi wystartować przy beginUtterance")
        XCTAssertEqual(discordMute.startCount, 1)

        controller.cancelUtterance()

        XCTAssertEqual(controller.state, .idle, "Escape musi wrócić do .idle")
        XCTAssertEqual(engine.endCount, 1, "silnik ASR musi zostać zatrzymany")
        XCTAssertTrue(injector.applyPlans.isEmpty, "cancelUtterance NIGDY nie wstrzykuje na żywo")
        XCTAssertTrue(injector.clipboardTexts.isEmpty, "cancelUtterance NIGDY nie woła applyFinal (zero wklejania przez schowek)")

        // Ducking jest ODROCZONY (ta sama semantyka co endUtterance, próg
        // domyślny 1.5s) — po progu MUSI się cofnąć, dokładnie jak przy
        // normalnym końcu dyktowania.
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertEqual(ducker.stopCount, 1, "ducking musi się cofnąć po anulowaniu")
        XCTAssertEqual(discordMute.stopCount, 1)
    }

    func testCancelUtteranceWhenNotListeningIsNoOp() {
        let (controller, engine, injector, ducker, _) = makeController()

        XCTAssertEqual(controller.state, .idle)
        controller.cancelUtterance()

        XCTAssertEqual(controller.state, .idle, "poza .listening cancelUtterance nic nie zmienia")
        XCTAssertEqual(engine.endCount, 0)
        XCTAssertEqual(ducker.stopCount, 0)
        XCTAssertTrue(injector.applyPlans.isEmpty)
        XCTAssertTrue(injector.clipboardTexts.isEmpty)
    }
}
