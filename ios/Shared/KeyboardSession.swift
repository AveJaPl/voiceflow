import Foundation

struct KeyboardSessionSnapshot: Codable {
    enum Phase: String, Codable { case idle, preparing, recording, processing, result, error }
    var id: UUID
    var phase: Phase
    var level: Float = 0
    var text: String = ""
    var updatedAt = Date()

    func isLive(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) >= 0 && now.timeIntervalSince(updatedAt) < 3
    }
    func mayAutoInsert(now: Date, requestedAt: Date?, sameDocument: Bool, consumed: Bool) -> Bool {
        guard phase == .result, !consumed, sameDocument, let requestedAt,
              updatedAt >= requestedAt else { return false }
        return PendingInsert.shouldInsert(text: text, insertedAt: updatedAt, now: now)
    }

}

enum KeyboardSessionStore {
    static let automaticInsertionKey = "keyboard.automaticInsertion"
    static let stopKey = "keyboard.stopSessionID"
    static let consumedKey = "keyboard.consumedSessionID"
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("dictation-session.json")
    }
    static func read() -> KeyboardSessionSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeyboardSessionSnapshot.self, from: data)
    }
    static func write(_ state: KeyboardSessionSnapshot) {
        guard let url, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
    static var automaticallyInsert: Bool {
        AppGroup.defaults.object(forKey: automaticInsertionKey) as? Bool ?? true
    }
}
