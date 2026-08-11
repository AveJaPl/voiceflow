import Foundation

/// Czysta logika "czy jest świeży tekst do wstawienia" — bez UIKit, bez App
/// Group, testowalna wprost. Osobny typ zamiast rozrzuconych `if`-ów w
/// `KeyboardViewController`, żeby dało się to przetestować hardware-free
/// (kryterium weryfikacji #2 z zadania PIVOT #2, docs/plans/ios-voiceflow-app.md §7).
enum PendingInsert {
    /// Próg świeżości: dłużej niż to i tekst uznajemy za "porzucony" (np.
    /// user otworzył klawiaturę dużo później, w zupełnie innym kontekście)
    /// — NIE wstawiamy go automatycznie.
    static let freshWindow: TimeInterval = 60

    /// `now` jako parametr (nie `Date()` wewnątrz) — deterministyczne testy
    /// bez czekania na zegar.
    static func shouldInsert(text: String?, insertedAt: Date?, now: Date) -> Bool {
        guard let text, !text.isEmpty else { return false }
        guard let insertedAt else { return false }
        guard insertedAt <= now else { return false }
        return now.timeIntervalSince(insertedAt) < freshWindow
    }
}
