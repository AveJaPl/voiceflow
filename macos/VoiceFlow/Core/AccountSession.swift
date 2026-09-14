import Foundation
import Security

/// Konto na relayu (`relay/README.md`): e-mail + hasło → stały token konta.
/// Na Macu konto służy WYŁĄCZNIE do synchronizacji — historia dyktowań,
/// słownik, ustawienia między urządzeniami (`HistoryUploader`,
/// `AccountSync`). Nic nie płynie tym kanałem w trakcie dyktowania; audio i
/// tekst nie opuszczają maszyny.
///
/// Do 2026-09-14 ten sam token otwierał też WebSocket „zdalnego mikrofonu” i
/// zdalnego sterowania pulpitem z telefonu — obie funkcje wycięte razem z
/// zakładką „Mac” w apce iOS (docs/plans/2026-09-14-voiceflow-apple-publiczne-wydanie.md).

protocol PairingTokenStoring {
    func loadToken() -> String?
    func saveToken(_ token: String)
    func clearToken()
}

/// Token konta w Keychainie. UserDefaults to zwykły plist na dysku bez
/// szyfrowania — nieodpowiednie dla czegoś, co daje dostęp do całej historii
/// dyktowań konta.
///
/// Landmina (potwierdzona 2026-08-12): wpis dodany z CLI przez `security` ma
/// partition-list `apple-tool:` i apka go NIE odczyta — token trzeba
/// przepuścić przez jednorazowy import (`defaults voiceflow.pairingTokenImport`,
/// patrz `VoiceFlowApp.importPairingTokenIfNeeded`).
final class KeychainPairingTokenStore: PairingTokenStoring {
    private let service = "pl.programo.voiceflow.remoteMicToken"
    private let account = "pairingToken"

    func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) {
        clearToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func clearToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AccountError: LocalizedError {
    case invalidHost
    case invalidResponse
    case unauthorized
    case server(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "Adres serwera jest nieprawidłowy."
        case .invalidResponse: "Serwer zwrócił nieoczekiwaną odpowiedź."
        case .unauthorized: "Zły e-mail albo hasło."
        case .server(let code): "Serwer zwrócił błąd \(code)."
        case .transport(let message): "Nie mogę połączyć się z serwerem: \(message)"
        }
    }
}

enum AccountAPI {
    /// REST relaya siedzi pod tym samym adresem co jego WebSocket — użytkownik
    /// mógł wpisać `wss://`, sam host, albo `https://`. Wszystko schodzi do
    /// jednej bazy HTTP(S).
    static func httpBase(_ rawHost: String) throws -> String {
        var base = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw AccountError.invalidHost }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst("wss://".count) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst("ws://".count) }
        else if !base.hasPrefix("http://"), !base.hasPrefix("https://") { base = "https://" + base }
        guard URL(string: base) != nil else { throw AccountError.invalidHost }
        return base
    }

    /// `POST /login` → `{"pairToken": "..."}`. Ta sama para (e-mail + hasło)
    /// co w apce iOS; token jest stały dla konta, więc wystarczy raz.
    static func logIn(host: String, email: String, password: String) async throws -> String {
        let base = try httpBase(host)
        guard let url = URL(string: "\(base)/login") else { throw AccountError.invalidHost }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespaces),
            "password": password,
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.invalidResponse }
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 ? AccountError.unauthorized : AccountError.server(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["pairToken"] as? String, !token.isEmpty else {
            throw AccountError.invalidResponse
        }
        return token
    }
}
