import Foundation
import os.log

/// JSON w `~/Library/Application Support/VoiceFlow/notes.json`, zapis atomowy.
/// Bez chmury, bez konta (§"Notatki" w planie).
final class NotesStore {
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "NotesStore")
    private let fileURL: URL
    private let queue = DispatchQueue(label: "io.github.avejapl.voiceflow.notesstore")

    private(set) var notes: [Note] = []

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("VoiceFlow", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("notes.json")
        }
        load()
    }

    func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else {
                notes = []
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = (try? decoder.decode([Note].self, from: data)) ?? []
        }
    }

    @discardableResult
    func add(_ note: Note) -> Note {
        queue.sync {
            notes.insert(note, at: 0)
            persist()
        }
        return note
    }

    /// Podmienia notatkę o tym samym `id` (kontynuacja tej samej myśli po krótkiej
    /// przerwie w dyktowaniu, §"Kontrakty" w SessionController); jeśli nie ma
    /// notatki o tym `id`, dodaje ją tak jak `add`. Bez tego każda krótka przerwa
    /// (oddech) tworzyłaby osobną notatkę będącą prefiksem poprzedniej.
    @discardableResult
    func upsert(_ note: Note) -> Note {
        queue.sync {
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx] = note
            } else {
                notes.insert(note, at: 0)
            }
            persist()
        }
        return note
    }

    func delete(id: UUID) {
        queue.sync {
            notes.removeAll { $0.id == id }
            persist()
        }
    }

    /// Wołane wewnątrz `queue.sync` — zapis atomowy przez plik tymczasowy + rename.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(notes)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            log.error("Nie udało się zapisać notes.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
