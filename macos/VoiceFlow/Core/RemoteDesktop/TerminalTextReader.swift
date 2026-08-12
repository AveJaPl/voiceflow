import AppKit
import Foundation

/// Warstwa 3 podglądu (plan §3.2): treść okna terminala jako TEKST przez
/// AppleScript — czytelniejsza i tańsza niż zrzut ekranu, bez uprawnienia
/// „Nagrywanie ekranu". Wymaga za to „Automatyzacji" (NSAppleEventsUsageDescription
/// w Info.plist; system zapyta przy pierwszym użyciu).
///
/// Obsługiwany jest Terminal.app — u Wojtka sesje Claude Code żyją właśnie tam.
/// Inne terminale (iTerm2 itd.) wracają `nil`, co `RemoteControlHub` tłumaczy
/// na brak podglądu tekstowego, nie na błąd całej funkcji.
@MainActor
enum TerminalTextReader {

    /// Ostatnie `maxLines` linii zawartości zaznaczonej karty wskazanego okna
    /// Terminala; `nil` gdy się nie da (nie-Terminal, brak zgody, brak okna).
    static func lines(bundleID: String?, cgWindowID: CGWindowID, maxLines: Int = 40) -> [String]? {
        guard bundleID == "com.apple.Terminal" else { return nil }
        // Okno Terminala znajdujemy po `id` AppleScriptu — Terminal wystawia
        // `id of window` równy CGWindowID (zweryfikowane na macOS 15).
        let script = """
        tell application "Terminal"
            repeat with w in windows
                if id of w is \(cgWindowID) then
                    return contents of selected tab of w
                end if
            end repeat
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var errorInfo: NSDictionary?
        let output = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            DebugLog.write("RemoteDesktop", "AppleScript Terminal odmówił: \(errorInfo)")
            return nil
        }
        guard let contents = output.stringValue else { return nil }
        // Terminal oddaje CAŁY scrollback karty — tniemy do ogona i zdejmujemy
        // puste linie z końca (kursor zwykle stoi kilka pustych linii poniżej
        // ostatniej treści).
        var allLines = contents.components(separatedBy: "\n")
        while let last = allLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            allLines.removeLast()
        }
        return Array(allLines.suffix(maxLines))
    }
}
