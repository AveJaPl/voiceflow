import Foundation

/// Wynik jednego kroku lokalnej zgody — patrz `LocalAgreement`.
struct LocalAgreementStep: Equatable {
    /// Nowo potwierdzone słowa (delta) — do doklejenia do zewnętrznego,
    /// narastającego tekstu skomitowanego (`WhisperSpeechEngine.committedText`).
    let newlyCommitted: String
    /// Reszta bieżącej hipotezy okna, jeszcze niepewna (może się zmienić w
    /// kolejnym kroku).
    let volatile: String
}

/// Algorytm "local agreement" znany ze streamingowych implementacji Whispera
/// (np. whisper_streaming): hipoteza z bieżącego okna jest zamrażana
/// (commit) tylko na wspólnym prefiksie słów z hipotezą z POPRZEDNIEGO okna —
/// dwa kolejne okna muszą się zgodzić, zanim tekst przestaje być `.volatile`.
///
/// Referencyjna sonda badawcza (`tools/probes/etap0e-whispercpp/stream_probe.c`,
/// Etap 0e) świadomie NIE implementowała tego kroku — jej własny raport to
/// mówi wprost (`etap0e-wyniki.md` §6: "Prefix-locking / local-agreement: NIE
/// zaimplementowany w tej sondzie... to zadanie TextDiffer-a/tej klasy z
/// Etapu 1") i dowodzi w §4b, że bez tego kroku tekst na żywo ma WER
/// 50-100% zamiast 0-31% z pełnym kontekstem. Ta klasa jest więc pierwszą
/// realną implementacją tego wymogu, nie przeniesieniem gotowego kodu z sondy.
///
/// WAŻNE dla wołającego (`WhisperSpeechEngine`): `hypothesis` przekazywana do
/// `observe(hypothesis:)` MUSI dotyczyć WYŁĄCZNIE audio jeszcze nieskomitowanego
/// (okno dekodowania zaczyna się dokładnie tam, gdzie skończył się ostatni
/// commit) — inaczej porównanie prefiksowe słów jest niepoprawne, bo oba
/// porównywane teksty muszą liczyć słowa od tego samego punktu zero.
final class LocalAgreement {
    private var previousWords: [String] = []

    func observe(hypothesis: String) -> LocalAgreementStep {
        let words = Self.words(from: hypothesis)
        let agreeCount = Self.commonPrefixCount(previousWords, words)

        guard agreeCount > 0 else {
            previousWords = words
            return LocalAgreementStep(newlyCommitted: "", volatile: hypothesis)
        }

        let committedWords = words.prefix(agreeCount)
        let remainderWords = Array(words.dropFirst(agreeCount))
        previousWords = remainderWords
        return LocalAgreementStep(
            newlyCommitted: committedWords.joined(separator: " "),
            volatile: remainderWords.joined(separator: " ")
        )
    }

    /// Wołane przy resecie sesji dekodowania (np. rotacja/nowy start) — bez
    /// tego pierwsze okno po resecie porównywałoby się do słów sprzed niego.
    func reset() {
        previousWords = []
    }

    private static func words(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func commonPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] {
            i += 1
        }
        return i
    }
}
