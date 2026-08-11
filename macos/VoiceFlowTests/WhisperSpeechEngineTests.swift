import XCTest
import AVFoundation
@testable import VoiceFlow

/// Zbiera update'y z `SpeechEngine.updates` (AsyncStream) w tle — bezpieczne
/// odpytywanie z testu bez blokowania się na strumieniu, który nigdy się nie
/// kończy (`continuation.finish()` nie jest wołane, tak samo jak w
/// `AppleSpeechEngine` — silnik żyje przez cały czas procesu).
private actor UpdateCollector {
    private(set) var firstPartial: String?
    private(set) var latestText = ""

    func record(_ update: TranscriptUpdate) {
        switch update {
        case .volatile(let text):
            if firstPartial == nil, !text.isEmpty { firstPartial = text }
            latestText = text
        case .committed(let text):
            latestText = text
        case .finalized(let text):
            latestText = text
        }
    }
}

private final class RecordingInjector: TextInjecting, ClipboardInjecting {
    private(set) var applyPlans: [InjectionPlan] = []
    private(set) var clipboardTexts: [String] = []
    func apply(_ plan: InjectionPlan) throws { applyPlans.append(plan) }
    func insertViaClipboard(_ text: String) throws { clipboardTexts.append(text) }
}

/// Ducking/mute BEZ dotykania realnego audio systemowego ani CGEvent — testy
/// mają zero efektów ubocznych na maszynie, niezależnie od tego, co akurat
/// jest ustawione w prawdziwych `AudioDucker`/`DiscordMuteToggle`.
private final class NoOpDucking: AudioDucking {
    func start() {}
    func stop() {}
}
private final class NoOpDiscordMute: DiscordMuteToggling {
    func start() {}
    func stop() {}
}

/// Kryteria weryfikacji #3, #4, #5 planu (docs/plans/whisper-local-engine-pl.md):
/// prawdziwy plik WAV wpychany w tempie rzeczywistym przez `feed()`, bez
/// mikrofonu, bez sieci (model pobrany/załadowany PRZED pomiarem w `prewarm()`
/// — sieć podczas transkrypcji zweryfikowana ręcznie `lsof`, patrz raport
/// agenta), pierwszy partial i finalny tekst zalogowane przez `DebugLog`.
final class WhisperSpeechEngineTests: XCTestCase {
    /// Treść fixture (`say -v Zosia -o ... `, potem `ffmpeg` do 16kHz mono WAV)
    /// — TO SAMO zdanie "pl1" co w sondzie referencyjnej
    /// (`tools/probes/etap0e-whispercpp`, `etap0e-wyniki.md` §2), gdzie model
    /// `base` z pełnym kontekstem dał WER 0%.
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dyktowanie-pl.wav")
    }

    private static func loadFixtureChunks(frameSize: AVAudioFrameCount = 1600) throws -> (chunks: [AVAudioPCMBuffer], sampleRate: Double) {
        let file = try AVAudioFile(forReading: fixtureURL)
        guard let full = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("nie udało się zaalokować bufora fixture")
        }
        try file.read(into: full)
        return (chunk(full, frameSize: frameSize), file.processingFormat.sampleRate)
    }

    /// Tnie jeden duży bufor na mniejsze kawałki o formacie natywnym pliku —
    /// symuluje kolejne dostawy z prawdziwego tapu mikrofonu (tam ~1024 klatek
    /// na raz, patrz `AudioCapture.start`).
    private static func chunk(_ buffer: AVAudioPCMBuffer, frameSize: AVAudioFrameCount) -> [AVAudioPCMBuffer] {
        guard let source = buffer.floatChannelData else { return [] }
        var result: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        let channels = Int(buffer.format.channelCount)
        while offset < buffer.frameLength {
            let length = min(frameSize, buffer.frameLength - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length) else { break }
            piece.frameLength = length
            if let dest = piece.floatChannelData {
                for ch in 0..<channels {
                    memcpy(dest[ch], source[ch] + Int(offset), Int(length) * MemoryLayout<Float>.size)
                }
            }
            result.append(piece)
            offset += length
        }
        return result
    }

    /// Kryterium #3: `WhisperSpeechEngine` sam w sobie, bez `SessionController`.
    func testTranscribesWavFixtureInRealTime() async throws {
        let engine = WhisperSpeechEngine(language: "pl")
        try await engine.prewarm()

        let collector = UpdateCollector()
        Task {
            for await update in engine.updates {
                await collector.record(update)
            }
        }

        let (chunks, sampleRate) = try Self.loadFixtureChunks()
        XCTAssertFalse(chunks.isEmpty, "fixture WAV nie powinien być pusty")

        engine.beginUtterance()
        for piece in chunks {
            engine.feed(piece)
            let seconds = Double(piece.frameLength) / sampleRate
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        // Łaska po ostatnim kawałku audio — daje ostatniemu krokowi
        // dekodowania (co ~stepMs=300ms) szansę dobiec, zanim czytamy wynik.
        try await Task.sleep(nanoseconds: 700_000_000)
        engine.endUtterance()
        try await Task.sleep(nanoseconds: 300_000_000)

        let firstPartial = await collector.firstPartial
        let finalText = await collector.latestText
        DebugLog.write("Test", "WhisperSpeechEngine pierwszy partial: \"\(firstPartial ?? "")\"")
        DebugLog.write("Test", "WhisperSpeechEngine finalny tekst: \"\(finalText)\"")

        XCTAssertNotNil(firstPartial, "powinien pojawić się co najmniej jeden partial")
        XCTAssertFalse(finalText.isEmpty, "finalny tekst nie powinien być pusty")
        // Sanity na słowach kluczowych, nie ścisła równość znak-w-znak — ASR
        // nie jest deterministycznie idealny nawet dla tego samego audio.
        let lower = finalText.lowercased()
        XCTAssertTrue(lower.contains("dzień dobry") || lower.contains("dzien dobry"), "brak \"dzień dobry\" w: \(finalText)")
        XCTAssertTrue(lower.contains("tydzień") || lower.contains("tydzien"), "brak \"tydzień\" w: \(finalText)")
    }

    /// Kryterium #4: pełny cykl przez `SessionController` (jak realne
    /// dyktowanie), z `AudioCapture` karmionym plikiem zamiast mikrofonu
    /// (`AudioCapture.startOverride`/`stopOverride`, patrz jego doc-comment).
    @MainActor
    func testSessionControllerAppliesFinalTextFromWav() async throws {
        let engine = WhisperSpeechEngine(language: "pl")

        let audioCapture = AudioCapture()
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}

        let injector = RecordingInjector()
        let tmpNotesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-test-notes-\(UUID().uuidString).json")

        let controller = SessionController(
            audioCapture: audioCapture,
            engine: engine,
            injector: injector,
            notesStore: NotesStore(fileURL: tmpNotesURL),
            audioDucker: NoOpDucking(),
            discordMuteToggle: NoOpDiscordMute()
        )
        await controller.prewarm() // pobiera/ładuje model + odpala konsumpcję updates

        let (chunks, sampleRate) = try Self.loadFixtureChunks()
        let time = AVAudioTime(sampleTime: 0, atRate: sampleRate)

        controller.beginUtterance()
        for piece in chunks {
            audioCapture.onBuffer?(piece, time)
            audioCapture.onLevel?(0.05, 0)
            let seconds = Double(piece.frameLength) / sampleRate
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        // Patrz komentarz w `WhisperSpeechEngine.endUtterance` — batchowe
        // dekodowanie co `stepMs` znaczy, że `differ.displayedText` (który
        // `endUtterance()` czyta SYNCHRONICZNIE, bez await) może być odrobinę
        // w tyle za ostatnimi słowami. Krótka łaska = to samo, co dzieje się
        // naturalnie, gdy użytkownik puszcza skrót chwilę po skończeniu mówić.
        try await Task.sleep(nanoseconds: 700_000_000)
        controller.endUtterance()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(injector.clipboardTexts.isEmpty, "applyFinal powinien wstawić tekst przez schowek (oba tryby wstawiania go wołają)")
        let finalText = injector.clipboardTexts.last ?? ""
        DebugLog.write("Test", "SessionController applyFinal: \"\(finalText)\"")

        XCTAssertFalse(finalText.isEmpty)
        let lower = finalText.lowercased()
        XCTAssertTrue(lower.contains("dzień dobry") || lower.contains("dzien dobry"), "brak \"dzień dobry\" w applyFinal: \(finalText)")

        try? FileManager.default.removeItem(at: tmpNotesURL)
    }
}
