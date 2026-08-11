import Foundation

/// Rejestracja urządzenia i dołączenie do pokoju — odpowiednik
/// `src/voiceflow/roomsetup.py`, tyle że wynik zapisuje w `UserDefaults`,
/// bo tam macOS trzyma swoje ustawienia.
///
/// REST i WebSocket dzielą ten sam adres, więc `wss://` zamieniamy na `https://`.
enum RoomJoiner {

    enum JoinError: LocalizedError {
        case badServer
        case http(Int, String)
        case malformedResponse
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badServer: "Adres serwera jest nieprawidłowy"
            case .http(let code, let detail): "Serwer odpowiedział \(code): \(detail)"
            case .malformedResponse: "Serwer zwrócił nieoczekiwaną odpowiedź"
            case .network(let message): "Nie można połączyć się z serwerem: \(message)"
            }
        }
    }

    struct Joined {
        let code: String
        let token: String
        let roomName: String?
    }

    static func httpBase(_ server: String) throws -> String {
        var base = server.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst("wss://".count) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst("ws://".count) }
        guard base.hasPrefix("http://") || base.hasPrefix("https://"), URL(string: base) != nil else {
            throw JoinError.badServer
        }
        return base
    }

    private static func post(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw JoinError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw JoinError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JoinError.malformedResponse
        }
        return object
    }

    /// Zwraca token urządzenia, rejestrując ten Mac, jeśli jeszcze go nie ma.
    static func ensureDevice(server: String, name: String, existingToken: String) async throws -> String {
        if !existingToken.isEmpty { return existingToken }
        let base = try httpBase(server)
        guard let url = URL(string: "\(base)/api/devices") else { throw JoinError.badServer }
        let result = try await post(url, body: ["name": name, "platform": "macos"])
        guard let token = result["token"] as? String else { throw JoinError.malformedResponse }
        return token
    }

    static func createRoom(server: String, roomName: String?, displayName: String, existingToken: String) async throws -> Joined {
        let base = try httpBase(server)
        let token = try await ensureDevice(server: server, name: displayName, existingToken: existingToken)
        guard let url = URL(string: "\(base)/api/rooms") else { throw JoinError.badServer }
        let room = try await post(url, body: ["name": roomName ?? ""])
        guard let code = room["code"] as? String else { throw JoinError.malformedResponse }
        _ = try await joinExisting(base: base, code: code, token: token)
        return Joined(code: code, token: token, roomName: room["name"] as? String)
    }

    static func joinRoom(server: String, code: String, displayName: String, existingToken: String) async throws -> Joined {
        let base = try httpBase(server)
        let token = try await ensureDevice(server: server, name: displayName, existingToken: existingToken)
        let result = try await joinExisting(base: base, code: code.uppercased(), token: token)
        let room = result["room"] as? [String: Any]
        return Joined(code: code.uppercased(), token: token, roomName: room?["name"] as? String)
    }

    private static func joinExisting(base: String, code: String, token: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(base)/api/rooms/\(code)/join") else { throw JoinError.badServer }
        return try await post(url, body: ["token": token])
    }

    /// Zapisuje wynik dołączenia. Token urządzenia to sekret — nie trafia do
    /// żadnego logu ani do interfejsu, tylko tutaj.
    static func save(_ joined: Joined, server: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: SettingsKeys.roomEnabled)
        defaults.set(server, forKey: SettingsKeys.roomServer)
        defaults.set(joined.code, forKey: SettingsKeys.roomCode)
        defaults.set(joined.token, forKey: SettingsKeys.roomToken)
    }

    static func leave(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: SettingsKeys.roomEnabled)
    }
}
