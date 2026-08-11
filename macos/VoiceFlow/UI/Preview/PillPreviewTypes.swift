import Foundation

// MARK: - Atrapy typów do podglądu UI (bez zależności na Core/)
//
// Realne odpowiedniki dostarczy drugi agent w Core/ i Model/. Te typy istnieją
// wyłącznie po to, żeby PillView/NotesWindow/SettingsView dały się napisać
// i podejrzeć niezależnie. Kształt jest zgodny z kontraktami z
// docs/plans/mac-mvp-implementation.md (TranscriptUpdate, InjectionPlan).

/// Stan pilla — odpowiada maszynie stanów SessionController z kontraktu.
enum PillPhase: Equatable {
    case idle
    case arming
    case listening
    case transcribing
    case finalizing
    /// Po zakończeniu dyktowania: pełny tekst (model.resultText) + przycisk
    /// kopiowania. Zostaje na ekranie kilka sekund, nie znika od razu jak
    /// wcześniejsze stany.
    case result
    case error(reason: String)
}

/// Notatka do podglądu okna notatek. Kształt zgodny z Model/Note.swift z kontraktu.
struct PreviewNote: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let finalText: String
    let rawText: String
    let targetApp: String
    let duration: TimeInterval
}

/// Minimalny opis urządzenia audio do listy w Ustawieniach.
struct PreviewAudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Tryb wstawiania tekstu — odpowiada drabinie z §7 planu.
enum InsertionMode: String, CaseIterable, Identifiable {
    case liveTyping
    case showThenInsert

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liveTyping: "Na żywo w trakcie mówienia"
        case .showThenInsert: "Pokaż w pillu, wstaw na końcu"
        }
    }
}

/// Język dyktowania.
enum DictationLanguage: String, CaseIterable, Identifiable {
    case polish
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .polish: "Polski"
        case .english: "English"
        }
    }
}
