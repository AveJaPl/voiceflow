import Foundation

/// Jedno zakończone dyktowanie (docs/plans/mac-mvp-implementation.md, Model).
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

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        finalText: String,
        rawText: String,
        targetBundleID: String?,
        duration: TimeInterval
    ) {
        self.id = id
        self.createdAt = createdAt
        self.finalText = finalText
        self.rawText = rawText
        self.targetBundleID = targetBundleID
        self.duration = duration
    }
}
