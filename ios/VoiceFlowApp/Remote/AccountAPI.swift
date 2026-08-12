import Foundation

/// HTTP-owa część relaya: logowanie kontem i historia dyktowań
/// (`relay/src/createServer.js` — `POST /login`, `GET|DELETE /history`).
///
/// WebSocket (`RemotePairing.relayURL`) i to API jeżdżą po TYM SAMYM tokenie
/// konta: `pairToken` z logowania trafia do `RemoteCredentials.token`, a stąd
/// do nagłówka `Authorization: Bearer`. Dlatego token ze starego parowania QR
/// dostanie z `/history` odpowiedź 401 — nie ma za nim konta.
enum AccountAPI {
    /// Publiczny relay na serwerze Wojtka (Coolify/Contabo) — jedyne miejsce
    /// w apce, które zna ten adres.
    static let defaultHost = "wss://o35lo8pceb0fmc10ziul6llo.161.97.135.88.sslip.io"

    enum Failure: Error, Equatable {
        case unauthorized
        case http(Int)
        case badResponse
        case transport(String)

        /// Komunikat dla człowieka — UI nigdy nie składa własnych zdań z kodów.
        var message: String {
            switch self {
            case .unauthorized: "Zaloguj się kontem w Ustawieniach."
            case .http(let status): "Serwer zwrócił błąd \(status)."
            case .badResponse: "Serwer odpowiedział w nieoczekiwanym formacie."
            case .transport(let why): "Nie mogę połączyć się z serwerem: \(why)."
            }
        }
    }

    // MARK: - Logowanie

    /// Zwraca `pairToken`, czyli dokładnie to, co dawał kod QR.
    static func logIn(email: String, password: String, host: String = defaultHost) async throws -> String {
        var request = URLRequest(url: try endpoint(host: host, path: "/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespaces),
            "password": password,
        ])
        let (data, status) = try await send(request)
        guard status == 200 else {
            throw status == 401 ? Failure.unauthorized : Failure.http(status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["pairToken"] as? String, !token.isEmpty
        else { throw Failure.badResponse }
        return token
    }

    // MARK: - Historia

    /// `before` = `createdAt` ostatniego znanego wpisu; serwer zwraca starsze.
    static func history(
        credentials: RemoteCredentials,
        limit: Int,
        before: Date? = nil
    ) async throws -> [HistoryEntry] {
        var components = URLComponents(url: try endpoint(host: credentials.host, path: "/history"),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            items.append(URLQueryItem(name: "before", value: isoOut.string(from: before)))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw Failure.badResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        guard status == 200 else {
            throw status == 401 ? Failure.unauthorized : Failure.http(status)
        }
        guard let payload = try? JSONDecoder().decode(HistoryPayload.self, from: data) else {
            throw Failure.badResponse
        }
        return payload.entries
    }

    /// Wysyła jedno dyktowanie do historii konta (telefon = source "phone").
    static func postHistory(
        credentials: RemoteCredentials,
        text: String,
        createdAt: Date,
        durationSeconds: Double,
        source: String
    ) async throws {
        var request = URLRequest(url: try endpoint(host: credentials.host, path: "/history"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "durationSeconds": durationSeconds,
            "source": source,
        ])
        let (_, status) = try await send(request)
        guard (200...299).contains(status) else {
            throw status == 401 ? Failure.unauthorized : Failure.http(status)
        }
    }

    static func deleteHistoryEntry(id: Int, credentials: RemoteCredentials) async throws {
        var request = URLRequest(url: try endpoint(host: credentials.host, path: "/history/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (_, status) = try await send(request)
        // 404 = wpis już nie istnieje; z punktu widzenia UI to ten sam skutek.
        guard status == 204 || status == 404 else {
            throw status == 401 ? Failure.unauthorized : Failure.http(status)
        }
    }

    // MARK: - Model

    struct HistoryEntry: Identifiable, Equatable, Decodable {
        let id: Int
        let createdAt: Date
        let text: String
        let durationSeconds: Double
        let target: String?
        let source: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            durationSeconds = (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0
            target = try? c.decode(String.self, forKey: .target)
            source = (try? c.decode(String.self, forKey: .source)) ?? "mac"
            let raw = try c.decode(String.self, forKey: .createdAt)
            guard let date = AccountAPI.parseISO(raw) else {
                throw Failure.badResponse
            }
            createdAt = date
        }

        init(id: Int, createdAt: Date, text: String, durationSeconds: Double, target: String?, source: String) {
            self.id = id
            self.createdAt = createdAt
            self.text = text
            self.durationSeconds = durationSeconds
            self.target = target
            self.source = source
        }

        private enum CodingKeys: String, CodingKey {
            case id, createdAt, text, durationSeconds, target, source
        }

        /// Liczba słów — do statystyk na Pulpicie.
        var wordCount: Int {
            text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
    }

    private struct HistoryPayload: Decodable {
        let entries: [HistoryEntry]
    }

    // MARK: - Wnętrze

    private static func endpoint(host: String, path: String) throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? defaultHost : trimmed
        let http = base
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        let withScheme = http.hasPrefix("http") ? http : "https://\(http)"
        guard let url = URL(string: withScheme + path), url.host?.isEmpty == false else {
            throw Failure.badResponse
        }
        return url
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw Failure.badResponse
            }
            return (data, status)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// Serwer zapisuje `new Date().toISOString()` (z milisekundami), ale wpisy
    /// mogą przyjść też bez nich — próbujemy obu wariantów.
    private static func parseISO(_ raw: String) -> Date? {
        isoIn.date(from: raw) ?? isoOut.date(from: raw)
    }

    private static let isoIn: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// E-mail zalogowanego konta. Serwer nie zwraca go przy `/login`, więc to
/// jedyne miejsce, w którym apka w ogóle wie, „kto jest zalogowany" — czysto
/// kosmetyczne, nie jest częścią uwierzytelniania.
enum AccountIdentity {
    private static let key = "account.email"

    static var email: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// Czas mówienia po ludzku: „42 s", „2 min 5 s".
enum VFDuration {
    static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(max(total, 0)) s" }
        return "\(total / 60) min \(total % 60) s"
    }
}
