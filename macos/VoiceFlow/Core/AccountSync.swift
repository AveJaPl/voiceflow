import Combine
import Foundation

/// Synchronizacja słownika między urządzeniami konta (`PUT/GET /vocabulary`
/// na relayu). Zasada „ostatni zapis wygrywa” z jednym zabezpieczeniem:
/// przy starcie bierzemy wersję z serwera tylko wtedy, gdy jest nowsza niż
/// nasza ostatnia wysyłka — inaczej Mac, który był offline, nadpisałby
/// świeży słownik z telefonu starą kopią, albo odwrotnie.
///
/// Historia idzie osobną drogą (`HistoryUploader`), bo to strumień wpisów,
/// nie jeden dokument.
@MainActor
final class AccountSync {
    private let tokenStore: PairingTokenStoring
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private static let syncedAtKey = "voiceflow.vocabularySyncedAt"

    init(tokenStore: PairingTokenStoring = KeychainPairingTokenStore(), defaults: UserDefaults = .standard) {
        self.tokenStore = tokenStore
        self.defaults = defaults
    }

    private var baseURL: String? {
        let stored = defaults.string(forKey: SettingsKeys.accountHost) ?? ""
        return try? AccountAPI.httpBase(stored.isEmpty ? SettingsView.defaultAccountHost : stored)
    }

    /// Wołane przy starcie i po zalogowaniu. Wysyłka po każdej zmianie
    /// słownika w Ustawieniach — z sekundą zwłoki, żeby nie słać po każdej literze.
    func start(settings: SettingsModel) {
        Task { await pull() }
        settings.$customVocabulary
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] words in Task { await self?.push(words) } }
            .store(in: &cancellables)
    }

    func pull() async {
        guard let token = tokenStore.loadToken(), !token.isEmpty, let base = baseURL,
              let url = URL(string: "\(base)/vocabulary") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = object["vocabulary"] as? [String],
              let updatedAt = (object["updatedAt"] as? String).flatMap(Self.parseISO) else { return }
        let syncedAt = defaults.object(forKey: Self.syncedAtKey) as? Date ?? .distantPast
        guard updatedAt > syncedAt else { return }
        defaults.set(words, forKey: SettingsKeys.customVocabulary)
        defaults.set(updatedAt, forKey: Self.syncedAtKey)
        DebugLog.write("AccountSync", "słownik z konta: \(words.count) słów (\(updatedAt))")
        NotificationCenter.default.post(name: Self.vocabularyDidChangeRemotely, object: nil)
    }

    func push(_ words: [String]) async {
        guard let token = tokenStore.loadToken(), !token.isEmpty, let base = baseURL,
              let url = URL(string: "\(base)/vocabulary") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["vocabulary": words])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updatedAt = (object["updatedAt"] as? String).flatMap(Self.parseISO) else { return }
        defaults.set(updatedAt, forKey: Self.syncedAtKey)
        DebugLog.write("AccountSync", "słownik wysłany na konto: \(words.count) słów")
    }

    /// Ustawienia po zdalnej zmianie słownika przeładowują listę z UserDefaults.
    static let vocabularyDidChangeRemotely = Notification.Name("voiceflow.vocabularyDidChangeRemotely")

    private static func parseISO(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
