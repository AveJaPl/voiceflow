import XCTest
@testable import VoiceFlow

final class TextDifferTests: XCTestCase {

    func testFirstHypothesisInsertsWholeString() {
        let d = TextDiffer()
        let plan = d.diff(toHypothesis: "cześć")
        XCTAssertEqual(plan, InjectionPlan(deleteCount: 0, insert: "cześć"))
        XCTAssertEqual(d.displayedText, "cześć")
    }

    func testWordLengthening() {
        // "jak" -> "jakby": czysta wydłużanka, minimalna operacja to dopisanie "by"
        let d = TextDiffer()
        _ = d.diff(toHypothesis: "jak")
        let plan = d.diff(toHypothesis: "jakby")
        XCTAssertEqual(plan, InjectionPlan(deleteCount: 0, insert: "by"))
    }

    func testGrowingSentenceWordByWord() {
        let d = TextDiffer()
        _ = d.diff(toHypothesis: "cześć")
        _ = d.diff(toHypothesis: "cześć jak")
        let plan = d.diff(toHypothesis: "cześć jak się")
        XCTAssertEqual(plan, InjectionPlan(deleteCount: 0, insert: " się"))
        XCTAssertEqual(d.displayedText, "cześć jak się")
    }

    func testBackwardCorrectionReplacesTail() {
        // "spotkajmy się we wtorek" -> "spotkajmy się, nie, w piątek"
        let d = TextDiffer()
        _ = d.diff(toHypothesis: "spotkajmy się we wtorek")
        let plan = d.diff(toHypothesis: "spotkajmy się w piątek")
        // wspólny prefiks: "spotkajmy się w" (litera "w" pasuje do początku "we")
        XCTAssertEqual(d.displayedText, "spotkajmy się w piątek")
        // Zastosowanie planu na starym tekście musi dać nową hipotezę.
        let old = "spotkajmy się we wtorek"
        let common = String(old.prefix(old.count - plan.deleteCount))
        XCTAssertEqual(common + plan.insert, "spotkajmy się w piątek")
    }

    func testFullReplacementWhenNoCommonPrefix() {
        let d = TextDiffer()
        _ = d.diff(toHypothesis: "abc")
        let plan = d.diff(toHypothesis: "xyz")
        XCTAssertEqual(plan, InjectionPlan(deleteCount: 3, insert: "xyz"))
    }

    func testFreezeStopsFurtherDeletionOfCommittedPrefix() {
        let d = TextDiffer()
        _ = d.diff(toHypothesis: "dzień dobry")
        _ = d.freeze(committedText: "Dzień dobry.")
        XCTAssertEqual(d.frozenPrefixCount, "Dzień dobry.".count)

        // Kolejna hipoteza z NOWEGO segmentu, która przez pomyłkę silnika
        // próbuje zmienić coś w zamrożonym prefiksie — musi zostać uszanowana
        // jako podłoga: diff liczy się tylko względem ogona.
        let plan = d.diff(toHypothesis: "Dzień dobry. Jak się masz")
        XCTAssertEqual(plan, InjectionPlan(deleteCount: 0, insert: " Jak się masz"))
    }

    func testFrozenPrefixNeverDeletedEvenOnDivergentHypothesis() {
        let d = TextDiffer()
        _ = d.freeze(committedText: "Programo")
        // Hipoteza kolejnego segmentu zaczyna się zupełnie inaczej niż zamrożony
        // tekst (bo to nowe zdanie) — nie wolno cofać się przed frozenPrefixCount.
        let plan = d.diff(toHypothesis: "Programoxyz")
        XCTAssertEqual(plan.deleteCount, 0)
        XCTAssertEqual(plan.insert, "xyz")
    }

    func testResetClearsState() {
        let d = TextDiffer()
        _ = d.freeze(committedText: "coś")
        d.reset()
        XCTAssertEqual(d.displayedText, "")
        XCTAssertEqual(d.frozenPrefixCount, 0)
        let plan = d.diff(toHypothesis: "nowe")
        XCTAssertEqual(plan, InjectionPlan(deleteCount: 0, insert: "nowe"))
    }

    func testSequenceOfPartialsProducesReconstructibleText() {
        // Cała sekwencja hipotez, jaką mogłby dać ASR na żywo — po zastosowaniu
        // wszystkich planów na wspólnym buforze musimy dostać ostatnią hipotezę.
        let hypotheses = [
            "no więc",
            "no więc jutro",
            "no więc jutro jedziemy",
            "no więc jutro jedziemy do",
            "jutro jedziemy do Poznania",
        ]
        let d = TextDiffer()
        var buffer = ""
        for h in hypotheses {
            let plan = d.diff(toHypothesis: h)
            let keep = String(buffer.prefix(buffer.count - plan.deleteCount))
            buffer = keep + plan.insert
            XCTAssertEqual(buffer, h)
        }
    }
}
