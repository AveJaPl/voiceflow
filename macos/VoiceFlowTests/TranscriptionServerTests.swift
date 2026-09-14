import XCTest
@testable import VoiceFlow

/// Kontrakt własnego serwera transkrypcji — od bajtów WAV, przez multipart,
/// po pełne kółko: `RemoteWhisperEngine` (klient) → `EngineShareServer`
/// (Mac udostępniający silnik) → odpowiedź. Silnik pod serwerem jest
/// atrapą, więc test sprawdza wyłącznie transport, nie jakość rozpoznania.
final class TranscriptionServerTests: XCTestCase {

    func testWavRoundTripKeepsSamples() throws {
        let samples: [Float] = (0..<16_000).map { sin(Float($0) / 16_000 * 2 * .pi * 440) * 0.5 }
        let wav = TranscriptionWire.wavData(samples: samples)
        let decoded = try XCTUnwrap(TranscriptionWire.samples(fromWAV: wav))
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.samples.count, samples.count)
        for index in stride(from: 0, to: samples.count, by: 997) {
            XCTAssertEqual(decoded.samples[index], samples[index], accuracy: 1.0 / 16_000)
        }
    }

    func testFixtureWavDecodesAndResamplesTo16k() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "dyktowanie-pl", withExtension: "wav"))
        let decoded = try XCTUnwrap(TranscriptionWire.samples(fromWAV: try Data(contentsOf: url)))
        let resampled = TranscriptionWire.resampleLinear(decoded.samples, from: decoded.sampleRate, to: 16_000)
        XCTAssertEqual(Double(resampled.count) / 16_000, 4.29, accuracy: 0.05, "próbka ma 4,29 s")
    }

    func testMultipartParsesFieldsAndFile() {
        let wav = TranscriptionWire.wavData(samples: [0.1, -0.1, 0.2])
        let body = TranscriptionWire.multipartBody(boundary: "abc123", wav: wav, language: "pl", prompt: "Programo, Estalo")
        let parsed = TranscriptionWire.parseMultipart(body: body, boundary: "abc123")
        XCTAssertEqual(parsed.fields["language"], "pl")
        XCTAssertEqual(parsed.fields["prompt"], "Programo, Estalo")
        XCTAssertEqual(parsed.fields["response_format"], "json")
        XCTAssertEqual(parsed.file, wav)
    }

    func testEndpointAcceptsBaseV1AndFullPath() {
        XCTAssertEqual(TranscriptionWire.endpoint(from: "192.168.1.10:8090")?.absoluteString, "http://192.168.1.10:8090/v1/audio/transcriptions")
        XCTAssertEqual(TranscriptionWire.endpoint(from: "https://api.openai.com/v1")?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(TranscriptionWire.endpoint(from: "http://mac:8090/v1/audio/transcriptions/")?.absoluteString, "http://mac:8090/v1/audio/transcriptions")
        XCTAssertNil(TranscriptionWire.endpoint(from: "   "))
    }

    @MainActor
    func testClientReachesShareServerAndGetsText() async throws {
        let received = Received()
        let server = EngineShareServer { samples, prompt in
            await received.record(count: samples.count, prompt: prompt)
            return "Dzień dobry z serwera"
        }
        server.start()
        // NWListener zgłasza `.ready` asynchronicznie.
        for _ in 0..<50 where !server.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(server.isRunning, "serwer nie wystartował na porcie \(server.port)")
        defer { server.stop() }

        let defaults = UserDefaults(suiteName: "voiceflow.tests.remote")!
        defaults.removePersistentDomain(forName: "voiceflow.tests.remote")
        defaults.set("http://127.0.0.1:\(server.port)", forKey: SettingsKeys.transcriptionServerURL)

        let audio = [Float](repeating: 0.01, count: 32_000)
        let text = try await RemoteWhisperEngine.transcribeRemotely(audio, language: "pl", prompt: "Programo", defaults: defaults)
        XCTAssertEqual(text, "Dzień dobry z serwera")
        let seen = await received.snapshot()
        XCTAssertEqual(seen.count, 32_000, "serwer ma dostać dokładnie te próbki, które wysłał klient")
        XCTAssertEqual(seen.prompt, "Programo")
    }
}

private actor Received {
    var count = 0
    var prompt = ""
    func record(count: Int, prompt: String) { self.count = count; self.prompt = prompt }
    func snapshot() -> (count: Int, prompt: String) { (count, prompt) }
}
