import Foundation

/// Klient wspólnego pokoju dyktowania — strona macOS.
///
/// Odpowiednik `src/voiceflow/room.py`, celowo reguła w regułę taki sam: obie
/// platformy rozmawiają z tym samym serwerem i muszą zachowywać się identycznie,
/// bo inaczej „kto może teraz mówić" zależałoby od tego, na czym kto siedzi.
///
/// Nie przechowuje audio ani tekstu. Publikuje dwa fakty — „zacząłem mówić" i
/// „skończyłem, N słów w M sekund" — i konsumuje jeden: kto, jeśli ktokolwiek,
/// mówi w tej chwili.
///
/// Transport jest wstrzykiwany, więc każda reguła poniżej daje się przetestować
/// bez sieci.

struct RoomConfiguration: Equatable {
    var enabled: Bool = false
    /// np. wss://rooms.pbdevs.com
    var server: String = ""
    /// Sześcioznakowy kod pokoju.
    var code: String = ""
    /// Token urządzenia z POST /api/devices.
    var token: String = ""
    /// Czy czyjeś dyktowanie może ściszyć dźwięk NA TYM urządzeniu.
    /// Uprawnienie, nie skutek uboczny obecności w pokoju.
    var duckForOthers: Bool = true

    /// Kanoniczny adres usługi pokoi — JEDNO miejsce.
    ///
    /// Wcześniej domyślny adres istniał wyłącznie jako wartość `@AppStorage`
    /// w `RoomSettingsSection`, a `@AppStorage` **nie zapisuje** domyślnej wartości
    /// do `UserDefaults` — jest tylko odpowiedzią na odczyt pustego klucza. Reszta
    /// aplikacji (`fromDefaults` niżej, `RoomClient`, zakładka Pokój) czytała więc
    /// pusty serwer i pokój nie mógł zadziałać: `isUsable` było zawsze fałszem, a
    /// żądania leciały na adres "".
    static let defaultServer = "wss://rooms.pbdevs.com"

    var isUsable: Bool { enabled && !server.isEmpty && !code.isEmpty && !token.isEmpty }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> RoomConfiguration {
        RoomConfiguration(
            enabled: defaults.bool(forKey: SettingsKeys.roomEnabled),
            server: {
                let stored = (defaults.string(forKey: SettingsKeys.roomServer) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                return stored.isEmpty ? RoomConfiguration.defaultServer : stored
            }(),
            code: (defaults.string(forKey: SettingsKeys.roomCode) ?? "").uppercased(),
            token: defaults.string(forKey: SettingsKeys.roomToken) ?? "",
            duckForOthers: defaults.object(forKey: SettingsKeys.roomDuckForOthers) == nil
                ? true
                : defaults.bool(forKey: SettingsKeys.roomDuckForOthers)
        )
    }
}

protocol RoomTransport: AnyObject {
    func send(_ payload: [String: Any])
    func onMessage(_ callback: @escaping ([String: Any]) -> Void)
}

@MainActor
final class RoomClient {

    private let config: RoomConfiguration
    private let onRemoteSpeaking: (String) -> Void
    private let onRemoteSilence: () -> Void
    private weak var transport: RoomTransport?

    /// Kto mówi GDZIE INDZIEJ, albo nil gdy w pokoju cisza.
    private(set) var remoteSpeaker: String?
    /// Czy to my ściszyliśmy tę maszynę dla kogoś innego. Przywrócenie musi
    /// nastąpić dokładnie raz: drugie ściszenie zapamiętałoby już ściszony
    /// poziom jako „oryginalny" i zostawiło ten komputer cicho na stałe.
    private var ducked = false

    init(
        config: RoomConfiguration,
        onRemoteSpeaking: @escaping (String) -> Void,
        onRemoteSilence: @escaping () -> Void,
        transport: RoomTransport? = nil
    ) {
        self.config = config
        self.onRemoteSpeaking = onRemoteSpeaking
        self.onRemoteSilence = onRemoteSilence
        self.transport = transport
        transport?.onMessage { [weak self] payload in
            Task { @MainActor in self?.handle(payload) }
        }
    }

    /// Czy lokalny skrót może zacząć nagrywać, i kto ewentualnie blokuje.
    func mayStart() -> (allowed: Bool, blockedBy: String?) {
        guard config.enabled else { return (true, nil) }
        guard let speaker = remoteSpeaker else { return (true, nil) }
        return (false, speaker)
    }

    func reportStarted() {
        send(["type": "speaking_started"])
    }

    func reportFinished(words: Int, seconds: Double) {
        send(["type": "speaking_ended", "words": words, "seconds": seconds])
    }

    /// Koniec mówienia bez niczego do zaraportowania — zwolnij pokój natychmiast.
    ///
    /// Anulowanie i nagranie, w którym nic nie powiedziano, nie wysyłały nic:
    /// pokój dalej pokazywał tę osobę jako mówiącą i blokował resztę aż do
    /// wygaśnięcia pulsu dziesięć sekund później. Zero słów to sygnał dla
    /// serwera, żeby zwolnić głos i nie zapisywać wpisu.
    func reportCancelled() {
        send(["type": "speaking_ended", "words": 0, "seconds": 0])
    }

    func heartbeat() {
        send(["type": "heartbeat"])
    }

    /// Serwer nieosiągalny: zapominamy o pokoju, zamiast trzymać jego blokadę.
    ///
    /// Pokój, którego nie widzimy, to pokój, który nie może nas blokować. Awaria
    /// sieci nie może odebrać dyktowania — to jest całe narzędzie. Głośność
    /// ściszoną dla kogoś innego przywracamy po drodze, bo nikt inny nam już
    /// tego nie każe.
    func onDisconnected() {
        setRemoteSpeaker(nil)
    }

    // MARK: - Plumbing

    private func send(_ payload: [String: Any]) {
        guard config.enabled, let transport else { return }
        transport.send(payload)
    }

    private func handle(_ payload: [String: Any]) {
        let kind = payload["type"] as? String
        if kind == "speaking_denied" {
            setRemoteSpeaker(payload["blockedBy"] as? String)
            return
        }
        guard kind == "speaker_changed" || kind == "room_state" else { return }
        let speaking = payload["speaking"] as? [String: Any]
        setRemoteSpeaker(speaking?["name"] as? String)
    }

    private func setRemoteSpeaker(_ name: String?) {
        guard name != remoteSpeaker else { return }
        remoteSpeaker = name
        guard let name else {
            if ducked {
                ducked = false
                onRemoteSilence()
            }
            return
        }
        if config.duckForOthers, !ducked {
            ducked = true
            onRemoteSpeaking(name)
        }
    }
}
