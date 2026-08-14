import Foundation

/// Kolejność terminali dla pilota (strzałki ◀ ▶) — czysta funkcja, żeby to,
/// co robi strzałka, dało się sprawdzić testem, a nie dopiero palcem na żywym
/// Macu.
///
/// Dlaczego NIE kolejność z ramki `windows`: tam okna są posortowane po `z`,
/// czyli po tym, które jest na wierzchu — a to zmienia się przy KAŻDYM
/// podniesieniu okna. Pilot sortujący po `z` przestawiałby sobie listę pod
/// palcem: dwa razy „w prawo" wracałoby do punktu wyjścia. Sortujemy po pozycji
/// na biurku (góra→dół, lewo→prawo), tak samo jak `TerminalRegistry` po stronie
/// Maca — układ okien jest stały, więc „następny" znaczy zawsze to samo.
enum TerminalOrder {

    /// Terminale w stabilnej kolejności ekranowej.
    static func sorted(_ windows: [WireWindow]) -> [WireWindow] {
        windows.filter(\.isTerminal).sorted {
            ($0.y, $0.x, $0.id) < ($1.y, $1.x, $1.id)
        }
    }

    /// Terminal oddalony o `offset` od bieżącego, z zawijaniem na końcach —
    /// pilot ma cztery przyciski i nie ma w nim miejsca na „koniec listy".
    ///
    /// Punkt odniesienia: zaznaczenie z telefonu, a jak go nie ma — okno, które
    /// Mac zgłasza jako aktywne. Bez tego pierwsza strzałka po wejściu w pilota
    /// skakała na początek listy zamiast obok tego, na co właśnie patrzysz.
    static func step(from current: String?, in windows: [WireWindow], offset: Int) -> WireWindow? {
        let terminals = sorted(windows)
        guard !terminals.isEmpty else { return nil }
        let anchor = current ?? terminals.first(where: \.focused)?.id
        guard let anchor, let index = terminals.firstIndex(where: { $0.id == anchor }) else {
            // Nic sensownego do zaczepienia — zależnie od kierunku bierzemy
            // pierwszy albo ostatni, żeby ruch zawsze był widoczny.
            return offset >= 0 ? terminals.first : terminals.last
        }
        let count = terminals.count
        let next = ((index + offset) % count + count) % count
        return terminals[next]
    }
}
