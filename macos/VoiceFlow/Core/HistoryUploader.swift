import Foundation

/// Wysyła każde zakończone dyktowanie do historii konta na relayu
/// (`POST /history`, auth tokenem parowania konta z Keychaina) — z tej samej
/// historii czyta zakładka Historia i Pulpit w apce na telefonie.
///
/// Zasada: historia na serwerze jest KOPIĄ, lokalna (`NotesStore`) prawdą.
/// Nieudana wysyłka (offline, token bez konta — stary token z /pair dostaje
/// 401) ląduje w kolejce i ponawia się przy kolejnym dyktowaniu — dyktowanie
/// NIGDY nie czeka na sieć.
@MainActor
final class HistoryUploader {

    private let tokenStore: PairingTokenStoring
    private let defaults: UserDefaults
    /// Wpisy, których nie udało się wysłać — do ponowienia. Trzymane tylko
    /// w pamięci: po restarcie apki źródłem prawdy i tak jest lokalna historia.
    private var retryQueue: [Note] = []
    private static let maxQueued = 50

    init(tokenStore: PairingTokenStoring = KeychainPairingTokenStore(), defaults: UserDefaults = .standard) {
        self.tokenStore = tokenStore
        self.defaults = defaults
    }

    private var endpoint: URL? {
        let host = defaults.string(forKey: SettingsKeys.remoteMicHost) ?? ""
        guard !host.isEmpty else { return nil }
        let httpBase = host
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        return URL(string: "\(httpBase)/history")
    }

    /// Jednorazowy import CAŁEJ lokalnej historii na konto — żeby chmura miała
    /// też to, co podyktowano PRZED zalogowaniem. Deduplikacja względem tego,
    /// co już na serwerze (klucz: sekunda czasu + tekst), więc powtórne
    /// uruchomienie niczego nie dubluje. Flaga zapisuje się dopiero po
    /// KOMPLETNEJ wysyłce — przerwany import dokończy się przy następnym starcie.
    private static let backfillDoneKey = "voiceflow.historyBackfillDone"

    func backfillIfNeeded(notes: [Note]) {
        guard !defaults.bool(forKey: Self.backfillDoneKey) else { return }
        // E-mail pojawia się dopiero po zalogowaniu KONTEM — stary token z /pair
        // dostałby 401 na każdym wpisie.
        guard let email = defaults.string(forKey: SettingsKeys.accountEmail), !email.isEmpty else { return }
        Task { await backfill(notes: notes) }
    }

    private func backfill(notes: [Note]) async {
        guard let endpoint, let token = tokenStore.loadToken(), !token.isEmpty else { return }
        let iso = ISO8601DateFormatter()

        // Co już jest na serwerze — żeby nie dublować wpisów wysłanych na żywo.
        var existing = Set<String>()
        var listURL = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        listURL.queryItems = [URLQueryItem(name: "limit", value: "500")]
        var listRequest = URLRequest(url: listURL.url!)
        listRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: listRequest),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else {
            DebugLog.write("History", "import wsteczny: nie mogę odczytać stanu serwera — spróbuję przy następnym starcie")
            return
        }
        for entry in entries {
            guard let createdAt = entry["createdAt"] as? String, let text = entry["text"] as? String else { continue }
            existing.insert("\(String(createdAt.prefix(19)))|\(text)")
        }

        let pending = notes
            .sorted { $0.createdAt < $1.createdAt }
            .filter { !existing.contains("\(String(iso.string(from: $0.createdAt).prefix(19)))|\($0.finalText)") }
        guard !pending.isEmpty else {
            defaults.set(true, forKey: Self.backfillDoneKey)
            DebugLog.write("History", "import wsteczny: wszystko już na serwerze")
            return
        }
        DebugLog.write("History", "import wsteczny: wysyłam \(pending.count) wpisów lokalnej historii")
        for note in pending {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": note.finalText,
                "createdAt": iso.string(from: note.createdAt),
                "durationSeconds": note.duration,
                "target": note.targetBundleID as Any,
                "source": "mac",
            ])
            guard let (_, postResponse) = try? await URLSession.shared.data(for: request),
                  let status = (postResponse as? HTTPURLResponse)?.statusCode,
                  (200...299).contains(status) else {
                DebugLog.write("History", "import wsteczny przerwany — dokończę przy następnym starcie")
                return
            }
        }
        defaults.set(true, forKey: Self.backfillDoneKey)
        DebugLog.write("History", "import wsteczny zakończony: \(pending.count) wpisów na koncie")
    }

    func upload(_ note: Note) {
        retryQueue.append(note)
        if retryQueue.count > Self.maxQueued { retryQueue.removeFirst() }
        Task { await flush() }
    }

    private func flush() async {
        guard let endpoint, let token = tokenStore.loadToken(), !token.isEmpty else { return }
        while let note = retryQueue.first {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": note.finalText,
                "createdAt": ISO8601DateFormatter().string(from: note.createdAt),
                "durationSeconds": note.duration,
                "target": note.targetBundleID as Any,
                "source": "mac",
            ])
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
                if status == 401 {
                    // Token bez konta (stare parowanie z /pair) — historia
                    // konta nie istnieje. Nie ponawiamy w kółko; wpis wróci,
                    // bo kolejka nie jest czyszczona, a po zalogowaniu kontem
                    // kolejne dyktowanie ją opróżni.
                    DebugLog.write("History", "serwer odrzucił wpis (401) — zaloguj Maca kontem, żeby historia szła do chmury")
                    return
                }
                guard (200...299).contains(status) else {
                    DebugLog.write("History", "wysyłka historii nie powiodła się (HTTP \(status)) — ponowię później")
                    return
                }
                retryQueue.removeFirst()
            } catch {
                // Offline — wpis zostaje w kolejce, wróci przy następnym dyktowaniu.
                return
            }
        }
    }
}
