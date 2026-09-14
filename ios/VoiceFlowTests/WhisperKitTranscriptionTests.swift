import WhisperKit
import XCTest

/// Whisper przez WhisperKit na tej samej próbce, na której Mac testuje
/// whisper.cpp (`macos/VoiceFlowTests/WhisperSpeechEngineTests`). Model `base`
/// (74 MB, pobierany raz do katalogu tymczasowego symulatora) — test dowodzi,
/// że pobranie → załadowanie → transkrypcja po polsku działa end-to-end, nie
/// że `base` jest dokładny. Wzorzec sprawdzamy po słowach kluczowych, bo
/// `base` po polsku jest słabszy niż turbo używany na telefonie.
final class WhisperKitTranscriptionTests: XCTestCase {
    func testTranscribesPolishFixtureWithBaseModel() async throws {
        #if targetEnvironment(simulator)
        // Zmierzone 2026-09-14: w symulatorze Core ML liczy na CPU i po 180 s
        // oddaje PUSTY tekst dla tej samej próbki, którą ten sam model na
        // Macu transkrybuje poprawnie w 0,15 s (sonda `wkprobe`). Test ma
        // sens wyłącznie na urządzeniu: `xcodebuild test -destination id=<iPhone>`.
        throw XCTSkip("WhisperKit w symulatorze nie daje wiarygodnego wyniku — uruchom na urządzeniu")
        #endif
        let bundle = Bundle(for: Self.self)
        let wav = try XCTUnwrap(bundle.url(forResource: "dyktowanie-pl", withExtension: "wav"))
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wav.path)
        XCTAssertGreaterThan(audio.count, 16_000)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("whisperkit-tests")
        let folder = try await WhisperKit.download(variant: WhisperModelCatalog.base.variant, downloadBase: base)
        let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, download: false))

        let started = Date()
        let results = try await pipe.transcribe(
            audioArray: audio,
            decodeOptions: DecodingOptions(language: "pl", temperature: 0, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
        )
        let text = results.map(\.text).joined(separator: " ").lowercased()
        print("whisperkit base: \(text) (\(Date().timeIntervalSince(started)) s)")
        XCTAssertTrue(text.contains("dzień dobry") || text.contains("dzien dobry"), "brak „dzień dobry” w: \(text)")
        XCTAssertTrue(text.contains("tydzie"), "brak „tydzień” w: \(text)")
    }

    func testCatalogPicksTurboWhereSupportedAndSmallOtherwise() {
        XCTAssertEqual(WhisperModelCatalog.defaultModel(supported: [WhisperModelCatalog.largeTurbo.variant, "openai_whisper-small"]), WhisperModelCatalog.largeTurbo)
        XCTAssertEqual(WhisperModelCatalog.defaultModel(supported: ["openai_whisper-small", "openai_whisper-base"]), WhisperModelCatalog.small)
        XCTAssertEqual(WhisperModelCatalog.defaultModel(supported: ["openai_whisper-tiny"]), WhisperModelCatalog.base)
    }
}
