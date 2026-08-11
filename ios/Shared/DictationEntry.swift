import Foundation

/// Jeden wpis w historii dyktowań (App Group, `AppGroupKeys.dictationHistory`).
struct DictationEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    /// Skąd przyszedł ten wpis — do przyszłego rozróżnienia w UI historii.
    let source: Source

    enum Source: String, Codable {
        case keyboard
        case containerApp
    }

    init(id: UUID = UUID(), text: String, date: Date = Date(), source: Source) {
        self.id = id
        self.text = text
        self.date = date
        self.source = source
    }
}

/// Prosty magazyn historii w App Group UserDefaults — wystarczający na ten
/// etap (dziesiątki/setki wpisów tekstowych, nie dane wymagające bazy).
enum DictationHistoryStore {
    private static let maxEntries = 200

    static func load() -> [DictationEntry] {
        guard let data = AppGroup.defaults.data(forKey: AppGroupKeys.dictationHistory) else { return [] }
        return (try? JSONDecoder().decode([DictationEntry].self, from: data)) ?? []
    }

    static func append(_ entry: DictationEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
    }

    static func clear() {
        save([])
    }

    private static func save(_ entries: [DictationEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        AppGroup.defaults.set(data, forKey: AppGroupKeys.dictationHistory)
    }
}
