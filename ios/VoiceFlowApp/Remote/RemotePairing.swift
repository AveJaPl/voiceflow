import Foundation
import Security

/// Adres relaya + token, czyli wszystko, czego telefon potrzebuje, żeby dogadać
/// się z Makiem.
///
/// UWAGA NA PRZYSZŁOŚĆ: konta użytkowników buduje równolegle inny agent
/// (decyzja Wojtka 2026-08-11). Cała wiedza o tym, „skąd biorą się poświadczenia",
/// jest zamknięta w tym pliku — gdy konta wejdą, podmienia się `RemotePairing`
/// i ani `RemoteSession`, ani UI nie wiedzą o zmianie. Dlatego reszta apki nigdy
/// nie sięga po token bezpośrednio.
struct RemoteCredentials: Equatable {
    /// Baza relaya: pełny URL ze schematem (`wss://…`, `ws://127.0.0.1:8091`
    /// do testów lokalnych) albo sam host — wtedy domyślnie `wss://`.
    let host: String
    let token: String
}

enum RemotePairing {
    // MARK: - Adresy

    /// Ta sama konstrukcja co `RemoteMicClient.relayURL` po stronie macOS, tylko
    /// z rolą `phone`. Trzymane osobno, bo to jedyne miejsce w apce, które wie,
    /// jak wygląda URL relaya.
    static func relayURL(_ credentials: RemoteCredentials) -> URL? {
        let trimmed = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !credentials.token.isEmpty else { return nil }
        let withScheme = (trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://"))
            ? trimmed : "wss://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else { return nil }
        guard components.host?.isEmpty == false else { return nil }
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "phone"),
            URLQueryItem(name: "token", value: credentials.token),
        ]
        return components.url
    }

    // MARK: - Kod QR

    /// Parsuje ładunek z kodu QR pokazanego przez Maca. Akceptuje dwa kształty,
    /// bo nie wiadomo jeszcze, który wybierze implementacja kont:
    ///   1. `voiceflow-pair://pair?host=wss%3A%2F%2F…&token=…`
    ///   2. surowy JSON `{"host":"…","token":"…"}`
    /// Zwraca `nil` dla wszystkiego innego — skan przypadkowego kodu QR
    /// (bilet, paczka, Wi-Fi) nie może podmienić poświadczeń.
    static func parseQR(_ payload: String) -> RemoteCredentials? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = object["host"] as? String,
                  let token = object["token"] as? String
            else { return nil }
            return make(host: host, token: token)
        }

        guard trimmed.hasPrefix("voiceflow-pair://"),
              let components = URLComponents(string: trimmed),
              let items = components.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value
        else { return nil }
        return make(host: host, token: token)
    }

    private static func make(host: String, token: String) -> RemoteCredentials? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !t.isEmpty else { return nil }
        return RemoteCredentials(host: h, token: t)
    }
}

// MARK: - Przechowywanie

protocol RemoteCredentialStoring: AnyObject {
    func load() -> RemoteCredentials?
    func save(_ credentials: RemoteCredentials)
    func clear()
}

/// Token idzie do Keychaina, adres do `UserDefaults`.
///
/// To nie jest przesada: ten token pozwala zdalnie wstrzyknąć tekst i nacisnąć
/// Enter w dowolnym oknie Maca. `UserDefaults` to zwykły, nieszyfrowany plist —
/// ta sama decyzja co po stronie macOS (`KeychainPairingTokenStore`). Adres
/// relaya nie jest sekretem i trzymanie go w Keychainie tylko utrudniałoby
/// diagnostykę.
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
