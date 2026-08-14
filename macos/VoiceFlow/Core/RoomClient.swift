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
    /// Czy wysyłamy do pokoju zużycie Claude Code. Domyślnie TAK — parytet z
    /// wersją linuksową (`room.share_claude_usage`).
    var shareClaudeUsage: Bool = true

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
                : defaults.bool(forKey: SettingsKeys.roomDuckForOthers),
            shareClaudeUsage: defaults.object(forKey: SettingsKeys.roomShareClaudeUsage) == nil
                ? true
                : defaults.bool(forKey: SettingsKeys.roomShareClaudeUsage)
        )
    }
}

protocol RoomTransport: AnyObject {
    func send(_ payload: [String: Any])
    func onMessage(_ callback: @escaping ([String: Any]) -> Void)
    /// Puls ma odświeżać pokój TYLKO w trakcie mówienia — patrz `RoomLink`.
    /// Domyślnie nic, żeby atrapy w testach nie musiały o tym wiedzieć.
    func setSpeaking(_ value: Bool)
}

extension RoomTransport {
    func setSpeaking(_ value: Bool) {}
}

@MainActor
final class RoomClient {

    private let config: RoomConfiguration
    private let onRemoteSpeaking: (String) -> Void
    private let onRemoteSilence: () -> Void
    private weak var transport: RoomTransport?

    /// Kto mówi GDZIE INDZIEJ, albo nil gdy w pokoju cisza.
    private(set) var remoteSpeaker: String?
    /// Kiedy ostatnio serwer POTWIERDZIŁ mówiącego. Blokada grzecznościowa ma
    /// termin ważności: zawieszony klient innej osoby (apka ubita w środku
    /// wypowiedzi, ale wciąż pulsująca) potrafi trzymać serwerową blokadę
    /// godzinami — a dyktowanie na WŁASNYM Macu nie może przez to umrzeć.
    /// Zaobserwowane na żywo 2026-08-12: „mówi Jakub" bez końca, lokalny
    /// skrót martwy.
    private var remoteSpeakerConfirmedAt = Date.distantPast
    /// Po tylu sekundach bez świeżego potwierdzenia blokada wygasa lokalnie.
    static let speakerBlockTTL: TimeInterval = 30

    /// Testom nie wolno spać 30 sekund — cofamy potwierdzenie ręcznie.
    func expireSpeakerConfirmationForTests() {
        remoteSpeakerConfirmedAt = Date.distantPast
    }
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
        guard Date().timeIntervalSince(remoteSpeakerConfirmedAt) < Self.speakerBlockTTL else {
            DebugLog.write(
                "Room",
                "blokada „mówi \(speaker)” starsza niż \(Int(Self.speakerBlockTTL)) s — ignoruję (zawieszony klient?)"
            )
            return (true, nil)
        }
        return (false, speaker)
    }

    /// Czy TA maszyna mówi w tej chwili. Serwer nigdy nie odbija mówiącego do
    /// niego samego, więc `remoteSpeaker` nie może tego nieść — trzeba
    /// pamiętać osobno.
    private(set) var speakingHere = false

    func reportStarted() {
        speakingHere = true
        transport?.setSpeaking(true)
        send(["type": "speaking_started"])
    }

    func reportFinished(words: Int, seconds: Double) {
        speakingHere = false
        transport?.setSpeaking(false)
        send(["type": "speaking_ended", "words": words, "seconds": seconds])
    }

    /// Koniec mówienia bez niczego do zaraportowania — zwolnij pokój natychmiast.
    ///
    /// Anulowanie i nagranie, w którym nic nie powiedziano, nie wysyłały nic:
    /// pokój dalej pokazywał tę osobę jako mówiącą i blokował resztę aż do
    /// wygaśnięcia pulsu dziesięć sekund później. Zero słów to sygnał dla
    /// serwera, żeby zwolnić głos i nie zapisywać wpisu.
    func reportCancelled() {
        speakingHere = false
        transport?.setSpeaking(false)
        send(["type": "speaking_ended", "words": 0, "seconds": 0])
    }

    /// Kafelki tablicy pokoju: co gra i ile Claude Code spalił dziś na tej
    /// maszynie. Oba lecą PRZELOTEM — serwer je rozsyła i zapomina, nie ma na
    /// nie tabeli i mieć nie będzie (`rooms/src/wsHub.js`). Zamknięcie sesji
    /// nie zostawia śladu tego, czego kto słuchał.
    func reportNowPlaying(_ track: NowPlaying.Track?) {
        send(["type": "now_playing", "track": track?.asDictionary as Any? ?? NSNull()])
    }

    /// Dzielenie się zużyciem jest domyślnie WŁĄCZONE (jak u Filipa: pokój to
    /// wspólny stół, a to są gołe liczby bez śladu tego, nad czym ktoś siedzi),
    /// ale zostaje przełącznik dla tego, kto woli je zachować dla siebie.
    func reportClaudeUsage(_ payload: ClaudeUsageCounter.Payload?) {
        guard config.shareClaudeUsage else { return }
        send(["type": "claude_usage", "usage": payload?.asDictionary as Any? ?? NSNull()])
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

    /// Połączenie wróciło. Serwer kasuje mówiącego przy zamknięciu gniazda, więc
    /// jeśli w tej luce dalej mówimy, musimy się zgłosić ponownie — inaczej
    /// trwające dyktowanie znika z tablicy, a ktoś inny może zacząć równolegle.
    func onReconnected() {
        guard speakingHere else { return }
        DebugLog.write("Room", "połączenie wróciło w trakcie mówienia — zgłaszam się do pokoju ponownie")
        send(["type": "speaking_started"])
    }

    // MARK: - Plumbing

    private func send(_ payload: [String: Any]) {
        guard config.enabled, let transport else { return }
        transport.send(payload)
    }

    private func handle(_ payload: [String: Any]) {
        let kind = payload["type"] as? String
        if kind == "speaking_denied" {
            // Odmowa NIE odświeża terminu ważności: może pochodzić z
            // zawieszonej blokady na serwerze, a wtedy każde wciśnięcie
            // skrótu przedłużałoby ją w nieskończoność.
            setRemoteSpeaker(payload["blockedBy"] as? String, confirmsAlive: false)
            return
        }
        guard kind == "speaker_changed" || kind == "room_state" else { return }
        let speaking = payload["speaking"] as? [String: Any]
        setRemoteSpeaker(speaking?["name"] as? String)
    }

    private func setRemoteSpeaker(_ name: String?, confirmsAlive: Bool = true) {
        // Puls z serwera ODŚWIEŻA termin ważności blokady — także wtedy, gdy
        // mówiący się nie zmienił. Żywy mówca pulsuje, martwy nie.
        if name != nil, confirmsAlive { remoteSpeakerConfirmedAt = Date() }
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
