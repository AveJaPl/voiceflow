import Foundation
import os.log

/// Pobiera model whisper.cpp `ggml-base.bin` (multilingual, ~148 MB, wybór
/// zmierzony w `tools/probes/etap0e-whispercpp`, `etap0e-wyniki.md` §5) RAZ,
/// do `~/Library/Application Support/VoiceFlow/models/` — TA SAMA konwencja
/// katalogu co `NotesStore`/`DebugLog` w tym repo.
///
/// Plan (`docs/plans/whisper-local-engine-pl.md`) mówi o
/// `~/Library/Application Support/VoiceFlow/...` — apka w TYM repo nazywa się
/// nadal VoiceFlow (bundle `pl.programo.voiceflow`, `apps/mac/VoiceFlow/`), nie VoiceFlow;
/// zamiana nazwy nigdzie w historii repo się nie wydarzyła. Patrz raport agenta.
/// Model whisper.cpp do wyboru w Ustawieniach.
///
/// Linux jedzie na `large-v3-turbo`, bo tam whisper liczy się na GPU i jest to
/// darmowe. Homebrew'owy whisper.cpp na tym Macu **nie ma backendu Metal**
/// (`libggml` bez jednego symbolu Metal, brak `libggml-metal`), więc wszystko idzie
/// przez CPU i wielkość modelu przekłada się wprost na czas oczekiwania.
///
/// Zmierzone 2026-08-11 na `VoiceFlowTests/Fixtures/dyktowanie-pl.wav` (4,3 s mowy,
/// pełny przebieg, beam 5, 8 wątków):
///
/// | model | tekst | czas |
/// |---|---|---|
/// | `base` (148 MB) | poprawny, z przecinkiem | **1,2 s** |
/// | `large-v3-turbo-q5_0` (574 MB) | identyczny | 6,4 s |
///
/// Dlatego domyślny jest `base`: na czystym polskim daje ten sam wynik pięć razy
/// szybciej. Większy model ma sens przy żargonie, akcencie i hałasie — i dlatego
/// jest wyborem użytkownika, a nie decyzją podjętą za niego.
enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case base
    case largeV3TurboQ5 = "large-v3-turbo-q5_0"

    var id: String { rawValue }

    var fileName: String { "ggml-\(rawValue).bin" }

    var displayName: String {
        switch self {
        case .base: "base — szybki (148 MB)"
        case .largeV3TurboQ5: "large-v3-turbo — dokładniejszy, wolniejszy (574 MB)"
        }
    }

    var approximateBytes: Int64 {
        switch self {
        case .base: 147_000_000
        case .largeV3TurboQ5: 574_000_000
        }
    }

    /// Próg wykrywania uciętego pobrania — połowa oczekiwanego rozmiaru. Nie
    /// wymagamy dokładnego rozmiaru, bo plik na HF bywa aktualizowany.
    var minimumValidSize: Int64 { approximateBytes / 2 }

    static func current(_ defaults: UserDefaults = .standard) -> WhisperModelChoice {
        defaults.string(forKey: SettingsKeys.whisperModel).flatMap(WhisperModelChoice.init(rawValue:)) ?? .base
    }
}

enum WhisperModelProvisioner {
    private static let log = Logger(subsystem: "pl.programo.voiceflow", category: "WhisperModelProvisioner")

    private static func downloadURL(for choice: WhisperModelChoice) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(choice.fileName)")!
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("VoiceFlow/models", isDirectory: true)
    }

    static func modelURL(for choice: WhisperModelChoice) -> URL {
        modelsDirectory.appendingPathComponent(choice.fileName)
    }

    enum ProvisionError: LocalizedError {
        case downloadFailed(status: Int)
        case downloadTooSmall(bytes: Int64)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let status):
                return "Pobieranie modelu whisper.cpp nie powiodło się (HTTP \(status))"
            case .downloadTooSmall(let bytes):
                return "Pobrany model whisper.cpp jest podejrzanie mały (\(bytes) B) — przerwane pobieranie?"
            }
        }
    }

    /// Zwraca ścieżkę do modelu, pobierając go jeśli jeszcze nie istnieje na
    /// dysku. Wołane z `WhisperSpeechEngine.prewarm()`, przy starcie apki.
    static func ensureModelAvailable(_ choice: WhisperModelChoice = .current()) async throws -> URL {
        let destination = modelURL(for: choice)
        if isValid(at: destination, choice: choice) {
            DebugLog.write("WhisperModel", "model \(choice.rawValue) już obecny, pomijam pobieranie")
            return destination
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let url = downloadURL(for: choice)
        DebugLog.write(
            "WhisperModel",
            "pobieram \(choice.fileName) (~\(choice.approximateBytes / 1_000_000) MB) z \(url.absoluteString)"
        )
        log.info("Pobieranie modelu whisper.cpp rozpoczęte")

        let downloader = ProgressLoggingDownloader()
        let tmpLocation = try await downloader.download(from: url)

        let size = (try? FileManager.default.attributesOfItem(atPath: tmpLocation.path)[.size] as? Int64) ?? 0
        guard size >= choice.minimumValidSize else {
            try? FileManager.default.removeItem(at: tmpLocation)
            throw ProvisionError.downloadTooSmall(bytes: size)
        }

        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmpLocation, to: destination)
        DebugLog.write("WhisperModel", "pobrano \(choice.fileName), \(size / 1_000_000) MB")
        return destination
    }

    private static func isValid(at url: URL, choice: WhisperModelChoice) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
            return false
        }
        return size >= choice.minimumValidSize
    }
}

/// `URLSessionDownloadDelegate` opakowany w async/await, logujący postęp co
/// ~10% przez `DebugLog`. Delegat (nie `bytes(for:)` iterowane bajt-po-bajcie)
/// bo 148 MB w pętli Swifta po jednym bajcie na iterację byłoby zauważalnie
/// wolne — `URLSessionDownloadTask` robi to na poziomie systemu.
private final class ProgressLoggingDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastLoggedDecile = -1

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let decile = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 10)
        guard decile > lastLoggedDecile else { return }
        lastLoggedDecile = decile
        DebugLog.write(
            "WhisperModel",
            "pobieranie: \(totalBytesWritten / 1_000_000) / \(totalBytesExpectedToWrite / 1_000_000) MB (\(decile * 10)%)"
        )
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation?.resume(throwing: WhisperModelProvisioner.ProvisionError.downloadFailed(status: http.statusCode))
            continuation = nil
            return
        }
        // `location` jest kasowana zaraz po powrocie z tej metody — przenosimy
        // do własnego tymczasowego pliku, zanim continuation w ogóle wróci.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
