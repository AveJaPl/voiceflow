import Foundation
import Network

/// Pokój, który ktoś obok rozgłasza w sieci lokalnej.
///
/// Odpowiednik `DiscoveredRoom` z `app/voiceflow_app/discovery.py`. Dwie osoby
/// przy jednym biurku nie powinny przepisywać sześcioznakowego kodu — maszyna,
/// która jest w pokoju, rozgłasza go przez mDNS, a druga pokazuje przyciskiem.
/// Poza tą siecią kod i tak działa; wykrywanie jest skrótem, nigdy jedyną drogą.
struct DiscoveredRoom: Equatable, Identifiable {
    let code: String
    /// Nazwa pokoju, jeśli ją nadano.
    let name: String
    /// Czyja to maszyna — do pokazania „Salon · Filip".
    let host: String

    var id: String { code }
    var title: String { name.isEmpty ? "Pokój \(code)" : name }
    var subtitle: String { host.isEmpty ? code : "\(host) · \(code)" }
}

/// Reguły wykrywania — czyste funkcje, testowalne bez sieci, dokładnie jak po
/// stronie Linuksa (tam wydzielone do `discovery.py`, obok `avahi.py`).
enum RoomDiscoveryRules {
    static let serviceType = "_voiceflow._tcp"

    /// Klucze TXT — muszą być IDENTYCZNE jak na Linuksie, bo obie platformy
    /// rozgłaszają się w tej samej sieci i mają się wzajemnie widzieć.
    /// Token urządzenia NIGDY tu nie trafia: to sekret, a TXT czyta każdy.
    enum TXTKey {
        static let code = "code"
        static let room = "room"
        static let host = "host"
    }

    /// Buduje pokój z mapy TXT albo `nil`, gdy to nie jest nasz rekord.
    /// Rekord bez kodu jest niedołączalny, więc nie jest pokojem — pokazanie go
    /// dałoby przycisk prowadzący donikąd.
    static func room(fromTXT fields: [String: String]) -> DiscoveredRoom? {
        let code = (fields[TXTKey.code] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return nil }
        return DiscoveredRoom(
            code: code,
            name: (fields[TXTKey.room] ?? "").trimmingCharacters(in: .whitespaces),
            host: (fields[TXTKey.host] ?? "").trimmingCharacters(in: .whitespaces)
        )
    }

    /// Wyrzuca nasz własny pokój i zwija duplikaty, zachowując stabilną kolejność.
    ///
    /// Ten sam pokój przychodzi raz na interfejs sieciowy — kabel i wi-fi na
    /// jednej maszynie to normalny przypadek — a pokazany dwa razy wygląda jak
    /// dwa pokoje. Własny odpada, bo „dołącz" nic by nie zrobiło.
    static func visibleRooms(_ found: [DiscoveredRoom], ownCode: String = "") -> [DiscoveredRoom] {
        let mine = ownCode.trimmingCharacters(in: .whitespaces).uppercased()
        var seen = Set<String>()
        var rooms: [DiscoveredRoom] = []
        for room in found where room.code != mine && !seen.contains(room.code) {
            seen.insert(room.code)
            rooms.append(room)
        }
        return rooms
    }
}

/// Rozgłaszanie własnego pokoju i szukanie cudzych przez Bonjour.
///
/// UWAGA: od macOS 15 dostęp do sieci lokalnej wymaga zgody użytkownika ORAZ
/// deklaracji w `Info.plist` (`NSLocalNetworkUsageDescription` + `NSBonjourServices`).
/// Bez nich przeglądarka po prostu nic nie znajduje — bez błędu, bez logu, bez
/// żadnego sygnału, że czegoś brakuje. Oba klucze są ustawione w `project.yml`.
@MainActor
final class RoomDiscovery: ObservableObject {
    @Published private(set) var rooms: [DiscoveredRoom] = []

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var ownCode = ""

    // MARK: - Szukanie

    func startBrowsing() {
        guard browser == nil else { return }
        // `bonjourWithTXTRecord`, nie `bonjour`: bez TXT nie znamy kodu pokoju,
        // a sama nazwa usługi go nie niesie.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: RoomDiscoveryRules.serviceType, domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                DebugLog.write("RoomDiscovery", "przeglądanie sieci nie powiodło się: \(error)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        DebugLog.write("RoomDiscovery", "szukam pokoi w sieci lokalnej (\(RoomDiscoveryRules.serviceType))")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        rooms = []
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let found: [DiscoveredRoom] = results.compactMap { result in
            guard case .bonjour(let txt) = result.metadata else { return nil }
            var fields: [String: String] = [:]
            for key in [
                RoomDiscoveryRules.TXTKey.code,
                RoomDiscoveryRules.TXTKey.room,
                RoomDiscoveryRules.TXTKey.host,
            ] {
                if let value = txt[key] { fields[key] = value }
            }
            return RoomDiscoveryRules.room(fromTXT: fields)
        }
        rooms = RoomDiscoveryRules.visibleRooms(
            found.sorted { $0.code < $1.code }, ownCode: ownCode
        )
    }

    // MARK: - Rozgłaszanie

    /// Rozgłasza pokój, w którym jesteśmy, żeby maszyna obok mogła dołączyć
    /// jednym kliknięciem zamiast przepisywania kodu.
    func startAdvertising(code: String, roomName: String, hostName: String) {
        stopAdvertising()
        guard !code.isEmpty else { return }
        ownCode = code.uppercased()

        var txt = NWTXTRecord()
        txt[RoomDiscoveryRules.TXTKey.code] = ownCode
        txt[RoomDiscoveryRules.TXTKey.room] = roomName
        txt[RoomDiscoveryRules.TXTKey.host] = hostName

        do {
            // Port efemeryczny: nikt się tu nie łączy, usługa istnieje wyłącznie
            // po to, żeby nieść rekord TXT z kodem pokoju — tak samo jak wpis
            // Avahi po stronie Linuksa.
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: hostName.isEmpty ? "VoiceFlow" : hostName,
                type: RoomDiscoveryRules.serviceType,
                txtRecord: txt
            )
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    DebugLog.write("RoomDiscovery", "rozgłaszanie nie powiodło się: \(error)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            DebugLog.write("RoomDiscovery", "rozgłaszam pokój \(ownCode) w sieci lokalnej")
        } catch {
            DebugLog.write("RoomDiscovery", "nie udało się rozgłosić pokoju: \(error.localizedDescription)")
        }
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        ownCode = ""
    }
}
