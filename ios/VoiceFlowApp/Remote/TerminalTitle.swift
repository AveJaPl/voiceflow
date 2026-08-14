import Foundation

/// Skracanie tytułów okien Terminala do czegoś, co da się przeczytać na
/// telefonie.
///
/// Terminal.app składa tytuł z czterech części rozdzielonych „ — ":
/// `wojciechplonka — ✳ Estalo CRM — przegląd błędów — node ◂ claude --dangerously-skip-permissions — 130×88`
/// Na liście na telefonie widać z tego użytkownika i rozmiar okna, czyli
/// dokładnie te dwie rzeczy, które nie niosą żadnej informacji. Bierzemy
/// środek: nazwę sesji, którą ustawił sobie Claude albo powłoka.
enum TerminalTitle {

    /// Człon do pokazania człowiekowi. Pusty tytuł (Mac bez zgody „Nagrywanie
    /// ekranu") zwraca `nil` — wołający pokazuje wtedy numer porządkowy.
    static func short(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw
            .components(separatedBy: " — ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        let meaningful = parts.filter { !isUser($0) && !isGeometry($0) && !isCommand($0) }
        let chosen = meaningful.first ?? parts.first!
        let cleaned = stripSpinner(chosen)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Ostatni człon to rozmiar okna w znakach („130×88") — zawsze śmieć.
    private static func isGeometry(_ part: String) -> Bool {
        part.range(of: #"^\d+[x×]\d+$"#, options: .regularExpression) != nil
    }

    /// Pierwszy człon to nazwa użytkownika — ta sama w każdym oknie, więc nic
    /// nie rozróżnia.
    private static func isUser(_ part: String) -> Bool {
        part == NSUserName() || part.range(of: #"^[a-z][a-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// Człon z uruchomionym poleceniem („node ◂ claude --dangerously-skip-permissions").
    private static func isCommand(_ part: String) -> Bool {
        part.contains("◂") || part.hasPrefix("-") || part.contains("--")
    }

    /// Claude dokłada na początku obracający się znaczek postępu (✳ ⠂ ⠐ …),
    /// który przy każdym odświeżeniu jest inny i tylko miga na liście.
    private static func stripSpinner(_ part: String) -> String {
        var text = part
        while let first = text.unicodeScalars.first,
              !CharacterSet.alphanumerics.contains(first),
              !CharacterSet.punctuationCharacters.contains(first) || first == "·" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
