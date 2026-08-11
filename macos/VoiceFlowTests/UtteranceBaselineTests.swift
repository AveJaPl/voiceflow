import XCTest
@testable import VoiceFlow

/// Regresja dla realnego buga zgłoszonego 2026-08-09: "wrzuca dwa razy jednego
/// prompta — raz powiem, skończę, chcę mówić coś drugiego, a on to łączy".
///
/// Mechanizm: silnik ASR jest TRWAŁY (dźwignia 886 ms -> 83 ms) i zwraca
/// hipotezy NARASTAJĄCO od swojego startu. Druga wypowiedź przychodzi jako
/// "pierwsze zdanie drugie zdanie". Bez odcięcia baseline'u do pola trafiało
/// całe pierwsze zdanie po raz drugi.
///
/// Testujemy `TextDiffer` w dokładnie tym scenariuszu — to on decyduje, co
/// realnie zostanie wstrzyknięte do pola.
final class UtteranceBaselineTests: XCTestCase {

    /// Odpowiednik `SessionController.utteranceLocalText` — logika odcięcia.
    private func localText(full: String, baseline: String) -> String {
        guard full.hasPrefix(baseline) else { return full }
        return String(full.dropFirst(baseline.count)).trimmingCharacters(in: .whitespaces)
    }

    func testDrugaWypowiedzNiePowtarzaPierwszej() {
        let differ = TextDiffer()

        // --- Pierwsza wypowiedź: baseline pusty, silnik zwraca narastająco.
        var baseline = ""
        let plan1a = differ.diff(toHypothesis: localText(full: "Halo", baseline: baseline))
        XCTAssertEqual(plan1a.insert, "Halo")
        let plan1b = differ.diff(toHypothesis: localText(full: "Halo test", baseline: baseline))
        XCTAssertEqual(plan1b.insert, " test")
        XCTAssertEqual(differ.displayedText, "Halo test")

        // --- Użytkownik kończy, po przerwie zaczyna DRUGĄ wypowiedź.
        // Pole docelowe jest już "zamknięte" — differ startuje od zera, ale
        // silnik NADAL pamięta "Halo test" i będzie to zwracał w każdej hipotezie.
        differ.reset()
        baseline = "Halo test" // <- to jest ta poprawka; wcześniej zerowaliśmy to na ""

        let plan2a = differ.diff(toHypothesis: localText(full: "Halo test druga", baseline: baseline))
        XCTAssertEqual(plan2a.insert, "druga", "Druga wypowiedź NIE MOŻE zawierać pierwszej")
        XCTAssertEqual(plan2a.deleteCount, 0, "Nic nie powinno być kasowane na starcie nowej wypowiedzi")

        let plan2b = differ.diff(toHypothesis: localText(full: "Halo test druga wypowiedź", baseline: baseline))
        XCTAssertEqual(plan2b.insert, " wypowiedź")

        XCTAssertEqual(differ.displayedText, "druga wypowiedź",
                       "W polu ma stać wyłącznie druga wypowiedź")
    }

    func testBaselineNiePasujeDoHipotezyZwracaCalosc() {
        // Silnik zrotował żądanie (co ~47 s) i liczy od zera — hipoteza nie
        // zaczyna się już od baseline'u. Lepiej pokazać nadmiar niż uciąć
        // tekst w losowym miejscu i zgubić słowa użytkownika.
        let wynik = localText(full: "zupełnie nowy tekst", baseline: "stary baseline")
        XCTAssertEqual(wynik, "zupełnie nowy tekst")
    }

    func testKontynuacjaTejSamejMysliDokladaDoIstniejacego() {
        // Krótka przerwa (oddech) — baseline i differ NIE są resetowane,
        // więc tekst rośnie dalej z tego samego miejsca zamiast zaczynać od nowa.
        let differ = TextDiffer()
        let baseline = "wcześniejsze"

        _ = differ.diff(toHypothesis: localText(full: "wcześniejsze pierwsza", baseline: baseline))
        XCTAssertEqual(differ.displayedText, "pierwsza")

        let plan = differ.diff(toHypothesis: localText(full: "wcześniejsze pierwsza część", baseline: baseline))
        XCTAssertEqual(plan.insert, " część")
        XCTAssertEqual(plan.deleteCount, 0)
        XCTAssertEqual(differ.displayedText, "pierwsza część")
    }
}
