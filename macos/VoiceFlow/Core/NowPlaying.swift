import AppKit
import Foundation

/// Co teraz gra na tej maszynie — kafelek na tablicy pokoju.
///
/// Parytet z wersją linuksową (`src/voiceflow/nowplaying.py`), ale INNĄ drogą:
/// tam jest MPRIS przez `busctl`, czyli jeden standard dla wszystkich
/// odtwarzaczy. macOS nie ma odpowiednika — prywatne `MediaRemote`, którym
/// chodziły dawne narzędzia, zostało w macOS 15.4 zamknięte dla aplikacji bez
/// uprawnień Apple'a. Zostaje AppleScript do odtwarzaczy, które go wystawiają:
/// Muzyka i Spotify. Przeglądarki (YouTube) nie wystawiają nic i tego się nie
/// obejdzie — kafelek po prostu ich nie pokaże.
///
/// Ładunek jest IDENTYCZNY jak z Linuksa, więc tablica pokoju rysuje oba
/// komputery tym samym kodem.
///
/// Ten kod nie ma prawa niczego opóźnić: to ozdoba przy narzędziu do
/// dyktowania. Dlatego woła się go z wątku POBOCZNEGO — AppleScript do
/// zamulonego odtwarzacza potrafi wisieć ułamek sekundy, a na głównym wątku
/// byłoby to widać jako zacięcie pilla.
enum NowPlaying {

    struct Track: Equatable {
        let title: String
        let artist: String
        /// Nazwa aplikacji („Spotify"), nie identyfikator pakietu.
        let player: String
        /// Publiczny adres okładki; pusty, gdy odtwarzacz go nie podał.
        let artURL: String

        var asDictionary: [String: Any] {
            ["title": title, "artist": artist, "player": player, "artUrl": artURL]
        }
    }

    /// Odtwarzacze w kolejności pytania. Pytamy TYLKO te, które już działają —
    /// odwołanie się AppleScriptem do zamkniętej aplikacji URUCHAMIA ją, a
    /// odpalenie komuś Muzyki dlatego, że chcieliśmy narysować kafelek, byłoby
    /// zachowaniem nie do obrony.
    private static let players: [(bundleID: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Muzyka"),
    ]

    static func currentTrack() -> Track? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for player in players where running.contains(player.bundleID) {
            if let track = track(fromPlayer: player) { return track }
        }
        return nil
    }

    private static func track(fromPlayer player: (bundleID: String, name: String)) -> Track? {
        // Jeden skrypt zwraca wszystko naraz — cztery osobne wywołania
        // AppleScriptu to cztery skoki międzyprocesowe na kafelek.
        let application = player.name == "Spotify" ? "Spotify" : "Music"
        let artwork = application == "Spotify" ? "artwork url of current track" : "\"\""
        let source = """
        tell application "\(application)"
            if player state is playing then
                set t to name of current track
                set a to artist of current track
                set u to \(artwork)
                return t & "\\n" & a & "\\n" & u
            end if
        end tell
        return ""
        """

        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            // Najczęstszy powód: brak zgody „Automatyzacja" dla tego
            // odtwarzacza. Logujemy raz na wywołanie i idziemy dalej — brak
            // kafelka nie może zatrzymać niczego innego.
            DebugLog.write("NowPlaying", "\(application): \(error[NSAppleScript.errorMessage] ?? "błąd")")
            return nil
        }
        let lines = (output.stringValue ?? "").components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        let title = lines[0].trimmingCharacters(in: .whitespaces)
        let artist = lines[1].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return Track(
            title: String(title.prefix(200)),
            artist: String(artist.prefix(200)),
            player: player.name,
            artURL: String((lines.count > 2 ? lines[2] : "").trimmingCharacters(in: .whitespaces).prefix(500))
        )
    }
}
