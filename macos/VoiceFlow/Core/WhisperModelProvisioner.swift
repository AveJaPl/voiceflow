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
enum WhisperModelProvisioner {
    private static let log = Logger(subsystem: "pl.programo.voiceflow", category: "WhisperModelProvisioner")
    private static let downloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
    )!
    /// Pełny plik ma ~148 MB; próg dużo niższy łapie ucięte/przerwane pobrania
    /// bez sztywnego wymogu dokładnego rozmiaru w bajtach (model może dostać
    /// drobną aktualizację na HF bez zmiany rzędu wielkości).
    private static let minimumValidSize: Int64 = 100_000_000

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("VoiceFlow/models", isDirectory: true)
    }

    static var modelURL: URL {
        modelsDirectory.appendingPathComponent("ggml-base.bin")
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
    static func ensureModelAvailable() async throws -> URL {
        if isValid(at: modelURL) {
            DebugLog.write("WhisperModel", "model już obecny, pomijam pobieranie")
            return modelURL
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        DebugLog.write("WhisperModel", "pobieram ggml-base.bin (~148 MB) z \(downloadURL.absoluteString)")
        log.info("Pobieranie modelu whisper.cpp rozpoczęte")

        let downloader = ProgressLoggingDownloader()
        let tmpLocation = try await downloader.download(from: downloadURL)

        let size = (try? FileManager.default.attributesOfItem(atPath: tmpLocation.path)[.size] as? Int64) ?? 0
        guard size >= minimumValidSize else {
            try? FileManager.default.removeItem(at: tmpLocation)
            throw ProvisionError.downloadTooSmall(bytes: size)
        }

        _ = try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: tmpLocation, to: modelURL)
        DebugLog.write("WhisperModel", "pobrano ggml-base.bin, \(size / 1_000_000) MB")
        return modelURL
    }

    private static func isValid(at url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
            return false
        }
        return size >= minimumValidSize
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
