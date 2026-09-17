import Foundation

struct KeyboardSessionRequest: Codable {
    let id: UUID
    let issuedAt: Date
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return age >= 0 && age < 15
    }
}

/// Thread-safe utterance gate. Idle microphone buffers are discarded before
/// conversion, and queued buffers from a previous utterance cannot enter a new one.
final class AudioUtteranceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    func set(_ value: UUID?) { lock.lock(); token = value; lock.unlock() }
    func get() -> UUID? { lock.lock(); defer { lock.unlock() }; return token }
}

/// Keep the microphone warm only while the keyboard is being used. The initial
/// handoff gets 60 seconds; subsequent gaps between keyboard appearances get 30.
enum KeyboardActivityPolicy {
    static func deadline(startedAt: Date, lastVisibleAt: Date?) -> Date {
        if let lastVisibleAt, lastVisibleAt >= startedAt {
            return lastVisibleAt.addingTimeInterval(30)
        }
        return startedAt.addingTimeInterval(60)
    }
}
