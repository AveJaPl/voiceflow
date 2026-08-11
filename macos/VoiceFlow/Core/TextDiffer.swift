import Foundation

/// Minimalna operacja do zastosowania w polu tekstowym: skasuj `deleteCount`
/// znaków wstecz od kursora, potem wpisz `insert`.
struct InjectionPlan: Equatable {
    let deleteCount: Int
    let insert: String

    /// Operacja pusta — nic się nie zmieniło.
    static let noop = InjectionPlan(deleteCount: 0, insert: "")

    var isNoop: Bool { deleteCount == 0 && insert.isEmpty }
}

protocol TextInjecting {
    func apply(_ plan: InjectionPlan) throws
}

/// Serce live typingu (docs/plans/mac-mvp-implementation.md §"Kontrakty"): dostaje
/// kolejne hipotezy ASR i zwraca najkrótszą operację (deleteCount, insert), która
/// zamienia to, co jest już wpisane w polu, na nową hipotezę.
///
/// Algorytm: local-agreement na wspólnym prefiksie znakowym. Zamrożony prefiks
/// (`freeze`, wołane na `committed`) nigdy nie jest kasowany przez kolejne
/// hipotezy `volatile` — to jest to, co Etap 0e nazwał "zamrażaniem uzgodnionego
/// prefiksu" i co bez tego daje WER 50-100% zamiast 0-31%.
///
/// Bez tego zamrożenia tekst na żywo rozjeżdżałby się wstecz za każdym razem,
/// gdy silnik poprawia wcześniejsze słowo już po tym, jak użytkownik zobaczył
/// je jako "pewne".
final class TextDiffer {
    /// Aktualny tekst wyświetlony/wstrzyknięty w polu — nasz model tego, co
    /// naprawdę tam stoi (nie odczytujemy pola z powrotem, bo to za wolne).
    private(set) var displayedText: String = ""

    /// Liczba znaków od początku `displayedText`, których już nie wolno skasować
    /// — ustawiana przez `freeze`.
    private(set) var frozenPrefixCount: Int = 0

    func reset() {
        displayedText = ""
        frozenPrefixCount = 0
    }

    /// Ustawia `displayedText` na `text` BEZ liczenia/zwracania planu — do użycia
    /// po operacji, która ominęła `diff()` (np. kasowanie+wklejenie przez schowek
    /// na finale), żeby wewnętrzny model różnic zgadzał się z tym, co naprawdę
    /// wylądowało w polu.
    func forceSet(_ text: String) {
        displayedText = text
        frozenPrefixCount = text.count
    }

    /// Nowa hipoteza (volatile albo pełny tekst po committed) — zwraca operację,
    /// która przeprowadzi obecny stan pola do tej hipotezy.
    @discardableResult
    func diff(toHypothesis hypothesis: String) -> InjectionPlan {
        let common = max(commonPrefixCount(displayedText, hypothesis), frozenPrefixCount)
        // Zamrożony prefiks musi być prefiksem obu stringów z definicji (był już
        // uzgodniony); common nie może więc wypaść poniżej niego.
        let safeCommon = min(common, min(displayedText.count, hypothesis.count))

        let deleteCount = displayedText.count - safeCommon
        let insert = suffix(of: hypothesis, from: safeCommon)

        displayedText = hypothesis
        return InjectionPlan(deleteCount: deleteCount, insert: insert)
    }

    /// Segment się ustabilizował (koniec zdania/EOU) — hipoteza staje się podłogą,
    /// której żadna kolejna `diff` nie skasuje.
    @discardableResult
    func freeze(committedText: String) -> InjectionPlan {
        let plan = diff(toHypothesis: committedText)
        frozenPrefixCount = displayedText.count
        return plan
    }

    // MARK: - Pomocnicze (operujemy na Character, nie UTF-16, żeby nie ciąć znaków złożonych)

    private func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            count += 1
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return count
    }

    private func suffix(of string: String, from charCount: Int) -> String {
        guard charCount < string.count else { return "" }
        let idx = string.index(string.startIndex, offsetBy: charCount)
        return String(string[idx...])
    }
}
