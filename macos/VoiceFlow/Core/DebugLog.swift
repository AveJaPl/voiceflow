import Foundation

/// Log do pliku, bo `os.Logger` na poziomie .info/.debug nie jest utrwalany
/// i `log show` zwraca pustkę — przy diagnozie „nic nie działa" to ślepa uliczka.
/// Plik: ~/Library/Logs/VoiceFlow/voiceflow.log
enum DebugLog {
    private static let queue = DispatchQueue(label: "io.github.avejapl.voiceflow.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiceflow.log")
    }()

    static func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
