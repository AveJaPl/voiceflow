import Foundation
import os.log

/// Historia dyktowań — **ten sam format co Linux i Windows**.
///
/// Jedna linia JSON na dyktowanie (JSONL) w
/// `~/Library/Application Support/VoiceFlow/history.jsonl`. Katalog jest
/// macowy, ale nazwa pliku, schemat i semantyka są wspólne z pozostałymi
/// platformami (`src/voiceflow/history.py`), bo Linux jest wzorcem dla całego
/// projektu. Dzięki temu ta sama historia daje się policzyć tym samym kodem
/// statystyk i przenieść między maszynami.
///
/// Wcześniej Mac trzymał `notes.json`: jedną wielką tablicę o własnym
/// schemacie, bez liczby słów i znaków (więc statystyk nie dało się policzyć),
/// bez limitu wielkości i przepisywaną W CAŁOŚCI po każdym dyktowaniu. Istniejący
/// plik jest jednorazowo przepisywany do nowego formatu przy pierwszym starcie.
///
/// Klucze `id`, `raw_text` i `target_bundle_id` są dodatkiem macOS ponad wspólny
/// schemat. Czytnik linuksowy bierze tylko znane sobie klucze i resztę pomija,
/// więc taki plik jest dla niego w pełni poprawny.
final class NotesStore {
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "NotesStore")
    private let fileURL: URL
    private let legacyURL: URL?
    private let queue = DispatchQueue(label: "io.github.avejapl.voiceflow.notesstore")

    /// Tyle najnowszych wpisów zostaje przy starcie — jak `history.max_entries`
    /// w konfiguracji linuksowej.
    private let maxEntries: Int

    private(set) var notes: [Note] = []

    init(fileURL: URL? = nil, maxEntries: Int = 20_000) {
        self.maxEntries = maxEntries
        if let fileURL {
            self.fileURL = fileURL
            self.legacyURL = nil
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("VoiceFlow", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.jsonl")
            self.legacyURL = dir.appendingPathComponent("notes.json")
        }
        migrateLegacyIfNeeded()
        load()
    }

    func load() {
        queue.sync {
            notes = Self.readAll(from: fileURL)
            if notes.count > maxEntries {
                notes = Array(notes.prefix(maxEntries))
                rewriteAll()
                log.info("Przycięto historię do \(self.maxEntries) wpisów")
            }
        }
    }

    @discardableResult
    func add(_ note: Note) -> Note {
        queue.sync {
            notes.insert(note, at: 0)
            append(note)
        }
        return note
    }

    /// Podmienia notatkę o tym samym `id`, w przeciwnym razie dopisuje.
    ///
    /// Dopisanie to jedna linia na koniec pliku — podmiana wymaga przepisania
    /// całości, więc jest tu wyraźnie droższą, rzadszą ścieżką. Odkąd każde
    /// wciśnięcie skrótu tworzy nową wypowiedź, praktycznie zawsze wchodzi ta
    /// pierwsza.
    @discardableResult
    func upsert(_ note: Note) -> Note {
        queue.sync {
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx] = note
                rewriteAll()
            } else {
                notes.insert(note, at: 0)
                append(note)
            }
        }
        return note
    }

    func delete(id: UUID) {
        queue.sync {
            notes.removeAll { $0.id == id }
            rewriteAll()
        }
    }

    // MARK: - Zapis

    /// Wołane wewnątrz `queue.sync`. Dopisanie jednej linii — tanie niezależnie
    /// od tego, jak duża jest już historia.
    private func append(_ note: Note) {
        guard let line = Self.encodeLine(note) else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: fileURL, options: .atomic)
            }
        } catch {
            log.error("Nie udało się dopisać do history.jsonl: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wołane wewnątrz `queue.sync`. Zapis atomowy przez plik tymczasowy.
    /// Plik trzyma najstarsze wpisy na górze — jak na Linuksie; `notes` jest
    /// posortowane od najnowszego, bo tak wyświetla je UI.
    private func rewriteAll() {
        let body = notes.reversed().compactMap(Self.encodeLine).joined()
        do {
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try Data(body.utf8).write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            log.error("Nie udało się zapisać history.jsonl: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Format wspólny z Linuksem

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Jedna linia JSONL. Kolejność kluczy jak w `history.py`, żeby plik dało
    /// się porównywać między platformami gołym okiem.
    static func encodeLine(_ note: Note) -> String? {
        var object: [String: Any] = [
            "timestamp": timestampFormatter.string(from: note.createdAt),
            "words": note.finalText.split(whereSeparator: { $0.isWhitespace }).count,
            "chars": note.finalText.count,
            "audio_seconds": (note.duration * 100).rounded() / 100,
            "transcription_seconds": 0,
            "injected": note.injected,
            "text": note.finalText,
            "id": note.id.uuidString,
        ]
        if !note.rawText.isEmpty { object["raw_text"] = note.rawText }
        if let bundleID = note.targetBundleID { object["target_bundle_id"] = bundleID }
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json + "\n"
    }

    static func decodeLine(_ line: String) -> Note? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestamp = object["timestamp"] as? String,
            let createdAt = timestampFormatter.date(from: timestamp)
        else { return nil }
        return Note(
            id: (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
            createdAt: createdAt,
            finalText: object["text"] as? String ?? "",
            rawText: object["raw_text"] as? String ?? "",
            targetBundleID: object["target_bundle_id"] as? String,
            duration: object["audio_seconds"] as? Double ?? 0,
            injected: object["injected"] as? Bool ?? true
        )
    }

    /// Najnowsze pierwsze — plik rośnie chronologicznie, UI czyta odwrotnie.
    /// Niezdatna linia jest pomijana, nie wywraca całej historii.
    private static func readAll(from url: URL) -> [Note] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { decodeLine(String($0)) }
            .reversed()
    }

    // MARK: - Migracja ze starego notes.json

    private func migrateLegacyIfNeeded() {
        guard
            let legacyURL,
            FileManager.default.fileExists(atPath: legacyURL.path),
            !FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: legacyURL)
        else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacyNotes = try? decoder.decode([Note].self, from: data), !legacyNotes.isEmpty else { return }

        // Stary plik trzymał najnowsze na początku; JSONL rośnie chronologicznie.
        let body = legacyNotes.reversed().compactMap(Self.encodeLine).joined()
        do {
            try Data(body.utf8).write(to: fileURL, options: .atomic)
            // Stary plik ZOSTAJE nietknięty jako kopia. Kasowanie historii
            // użytkownika w ramach zmiany formatu byłoby nie do obrony.
            log.info("Przeniesiono \(legacyNotes.count) notatek z notes.json do history.jsonl")
        } catch {
            log.error("Migracja notes.json nie powiodła się: \(error.localizedDescription, privacy: .public)")
        }
    }
}
