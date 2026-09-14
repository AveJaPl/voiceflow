import Foundation
import Security

/// Adres serwera konta + stały token konta. Nazwa `Remote*` została z czasów,
/// gdy ten sam token otwierał połączenie z Makiem; dziś to wyłącznie
/// poświadczenia do REST-owego `AccountAPI` (historia, słownik).
struct RemoteCredentials: Equatable {
    /// Pełny URL ze schematem (`https://…`; `wss://` też przechodzi) albo sam host.
    let host: String
    let token: String
}

protocol RemoteCredentialStoring: AnyObject {
    func load() -> RemoteCredentials?
    func save(_ credentials: RemoteCredentials)
    func clear()
}

/// Token idzie do Keychaina, adres do `UserDefaults`.
///
/// Ten token daje dostęp do całej historii dyktowań konta. `UserDefaults` to
/// zwykły, nieszyfrowany plist — ta sama decyzja co po stronie macOS
/// (`KeychainPairingTokenStore`). Adres serwera nie jest sekretem.
final class KeychainCredentialStore: RemoteCredentialStoring {
    private let service = "io.github.avejapl.voiceflow.ios.remote"
    private let account = "pairingToken"
    private let hostKey = "remote.host"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RemoteCredentials? {
        guard let host = defaults.string(forKey: hostKey), !host.isEmpty,
              let token = loadToken(), !token.isEmpty
        else { return nil }
        return RemoteCredentials(host: host, token: token)
    }

    func save(_ credentials: RemoteCredentials) {
        defaults.set(credentials.host, forKey: hostKey)
        saveToken(credentials.token)
    }

    func clear() {
        defaults.removeObject(forKey: hostKey)
        deleteToken()
    }

    // MARK: Keychain

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveToken(_ token: String) {
        deleteToken()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // `AfterFirstUnlock`, nie `WhenUnlocked`: apka może wrócić z tła przy
        // zablokowanym ekranie i musi umieć odtworzyć połączenie.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
