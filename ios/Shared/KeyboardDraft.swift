import Foundation

/// Extension-owned draft, separate from the app's live session heartbeat.
struct KeyboardDraft: Codable, Equatable {
    let sessionID: UUID
    var text: String
    var revision = UUID()
    var savedRevision: UUID?
    var accountKey: String?

    mutating func replace(with text: String) {
        guard self.text != text else { return }
        self.text = text
        revision = UUID()
    }
    var canInsertManually: Bool { !text.isEmpty }
    var needsHistorySave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && savedRevision != revision }

    static func load(defaults: UserDefaults = AppGroup.defaults) -> Self? {
        defaults.data(forKey: "keyboard.draft").flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func save(defaults: UserDefaults = AppGroup.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "keyboard.draft") }
    }
}
