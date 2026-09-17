import Combine
import CryptoKit
import Foundation

/// One account context for the whole app. Responses and pending uploads remain
/// bound to the credentials that started them, including across logout/login.
@MainActor
final class AccountSession: ObservableObject {
    static let shared = AccountSession()
    @Published private(set) var credentials: RemoteCredentials?
    @Published private(set) var history: [AccountAPI.HistoryEntry] = []
    @Published private(set) var vocabulary: [String] = []
    @Published private(set) var status = ""
    @Published private(set) var syncing = false
    private let store: RemoteCredentialStoring
    private let defaults: UserDefaults
    private var generation = UUID()
    private var vocabularyRevision = 0
    private var pendingVocabulary: [String]?
    private var syncAgain = false

    struct Upload: Codable {
        let entry: DictationEntry
        let duration: Double
        var uncertain = false
    }

    init(store: RemoteCredentialStoring = KeychainCredentialStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        credentials = store.load()
        loadVocabulary()
    }

    var isPaired: Bool { credentials != nil }
    var accountCredentials: RemoteCredentials? { credentials }
    var accountKey: String? { credentials.map(Self.key) }

    static func key(_ credentials: RemoteCredentials) -> String {
        SHA256.hash(data: Data((credentials.host + "\n" + credentials.token).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private var vocabularyKey: String {
        accountKey.map { "account.vocabulary.\($0)" } ?? "voiceflow.customVocabulary"
    }

    private func loadVocabulary() {
        vocabulary = defaults.stringArray(forKey: vocabularyKey) ?? []
        pendingVocabulary = accountKey.flatMap { defaults.stringArray(forKey: "account.vocabularyPending.\($0)") }
    }

    func updateCredentials(_ new: RemoteCredentials?) {
        generation = UUID()
        syncing = false
        syncAgain = false
        vocabularyRevision += 1
        if let new { store.save(new) } else { store.clear() }
        credentials = new
        history = []
        status = ""
        loadVocabulary()
        Task { await refresh() }
    }

    func updateVocabulary(_ words: [String]) {
        vocabularyRevision += 1
        vocabulary = words
        defaults.set(words, forKey: vocabularyKey)
        guard let accountKey else { return }
        pendingVocabulary = words
        defaults.set(words, forKey: "account.vocabularyPending.\(accountKey)")
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    func record(_ entry: DictationEntry, duration: Double, credentials owner: RemoteCredentials?) {
        guard let owner else { return }
        let key = Self.key(owner)
        var queue = uploads(key: key)
        guard !queue.contains(where: { $0.entry.id == entry.id }) else { return }
        queue.append(Upload(entry: entry, duration: duration))
        save(queue, key: key)
        if credentials == owner { Task { await refresh() } }
    }

    func refresh() async {
        guard let owner = credentials else { return }
        if syncing { syncAgain = true; return }
        let run = generation
        let key = Self.key(owner)
        let revision = vocabularyRevision
        syncing = true
        defer {
            if generation == run {
                syncing = false
                if syncAgain {
                    syncAgain = false
                    Task { await refresh() }
                }
            }
        }
        do {
            // Read first. A failed GET must never lead to blindly retrying a POST.
            let remote = try await AccountAPI.history(credentials: owner, limit: 500)
            guard generation == run, credentials == owner else { return }
            history = remote
            var uploaded = false
            for item in uploads(key: key) {
                guard generation == run, credentials == owner else { return }
                let source = "phone:\(item.entry.id.uuidString)"
                if remote.contains(where: { $0.source == source }) {
                    removeUpload(item.entry.id, key: key)
                    continue
                }
                // An ambiguous transport result may have been committed server-side.
                // Reconcile it on refresh, but never automatically post it twice.
                if item.uncertain { continue }
                markUncertain(item.entry.id, key: key) // persist before crossing network
                do {
                    try await AccountAPI.postHistory(credentials: owner, text: item.entry.text,
                        createdAt: item.entry.date, durationSeconds: item.duration, source: source)
                    removeUpload(item.entry.id, key: key)
                    uploaded = true
                } catch {
                    guard generation == run else { return }
                    status = "Nie potwierdzono zapisu na koncie. Tekst jest bezpieczny na telefonie; sprawdzę zapis przy odświeżeniu."
                    return
                }
            }
            if uploaded {
                let refreshed = try await AccountAPI.history(credentials: owner, limit: 500)
                guard generation == run else { return }
                history = refreshed
            }
            if let words = pendingVocabulary {
                try await AccountAPI.putVocabulary(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, credentials: owner)
                guard generation == run else { return }
                if vocabularyRevision == revision {
                    pendingVocabulary = nil
                    defaults.removeObject(forKey: "account.vocabularyPending.\(key)")
                } else { syncAgain = true }
            } else {
                let words = try await AccountAPI.vocabulary(credentials: owner)
                guard generation == run, vocabularyRevision == revision else { return }
                vocabulary = words
                defaults.set(words, forKey: vocabularyKey)
            }
            status = uploads(key: key).isEmpty ? "Historia i słownik są aktualne." : "Niektóre zapisy oczekują na potwierdzenie. Lokalna historia zachowuje tekst."
        } catch {
            guard generation == run else { return }
            status = (error as? AccountAPI.Failure)?.message ?? "Nie udało się odświeżyć konta. Spróbuj ponownie."
        }
    }

    private func uploads(key: String) -> [Upload] {
        guard let data = defaults.data(forKey: "account.uploads.\(key)") else { return [] }
        return (try? JSONDecoder().decode([Upload].self, from: data)) ?? []
    }
    private func save(_ queue: [Upload], key: String) {
        if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: "account.uploads.\(key)") }
    }
    private func removeUpload(_ id: UUID, key: String) { save(uploads(key: key).filter { $0.entry.id != id }, key: key) }
    private func markUncertain(_ id: UUID, key: String) {
        var queue = uploads(key: key)
        if let index = queue.firstIndex(where: { $0.entry.id == id }) { queue[index].uncertain = true }
        save(queue, key: key)
    }
}
