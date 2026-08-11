import Foundation

/// Jedno zakończone dyktowanie.
///
/// Model w pamięci dla UI. Na dysk idzie w formacie wspólnym z Linuksem i
/// Windowsem — patrz `NotesStore`, które mapuje te pola na klucze z
/// `src/voiceflow/history.py`.
struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    /// Tekst po Formatterze — to, co wylądowało w polu.
    let finalText: String
    /// Tekst surowy z ASR, przed Formatterem — do debugowania jakości transkrypcji.
    let rawText: String
    /// Bundle id aplikacji, do której tekst został wstrzyknięty (jeśli znany).
    let targetBundleID: String?
    /// Czas trwania wypowiedzi w sekundach.
    let duration: TimeInterval
    /// Czy tekst faktycznie trafił do aplikacji docelowej. Nieudane wstrzyknięcie
    /// też zapisujemy — wtedy historia jest jedyną drogą, żeby odzyskać tekst,
    /// i dokładnie po to Linux trzyma tę flagę.
    var injected: Bool = true

    /// `injected` celowo poza kluczami: jedyne, co jeszcze przechodzi przez
    /// `Codable`, to jednorazowa migracja starego `notes.json`, który tego pola
    /// nie zna. Brakująca wartość ma wtedy oznaczać „wstrzyknięto", a nie
    /// wywracać dekodowanie całej historii.
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, finalText, rawText, targetBundleID, duration
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        finalText: String,
        rawText: String,
        targetBundleID: String?,
        duration: TimeInterval,
        injected: Bool = true
    ) {
        self.id = id
        self.createdAt = createdAt
        self.finalText = finalText
        self.rawText = rawText
        self.targetBundleID = targetBundleID
        self.duration = duration
        self.injected = injected
    }
}
