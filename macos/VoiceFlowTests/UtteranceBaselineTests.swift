import XCTest
@testable import VoiceFlow

/// Kontrakt: KAŻDE wciśnięcie skrótu to nowa, niezależna wypowiedź.
///
/// Historia tego pliku jest częścią jego treści. Wcześniej silniki ASR
/// akumulowały transkrypt przez cały czas życia procesu, a `SessionController`
/// próbował odciąć poprzednie wypowiedzi, porównując prefiks tekstu ("baseline").
/// To założenie jest fałszywe: whisper rutynowo POPRAWIA już skomitowane słowa,
/// więc prefiks przestawał pasować i kod świadomie brał całość — druga
/// wypowiedź niosła w sobie pierwszą, wklejała ją ponownie i obie lądowały w
/// jednej notatce. Objaw zgłoszony 2026-08-11: „nie pojawia się nowe okienko,
/// tylko tak jakbym kontynuował, i zapisuje wszystko razem".
///
/// Naprawa siedzi w silnikach (`WhisperSpeechEngine.beginUtterance`,
/// `AppleSpeechEngine.beginUtterance`): transkrypt startuje od zera przy każdym
/// wciśnięciu, model zostaje załadowany. Testy poniżej pilnują skutku, który
/// widzi użytkownik — bez odejmowania prefiksów, bo już go nie ma.
final class UtteranceIsolationTests: XCTestCase {

    /// Druga wypowiedź wstawia WYŁĄCZNIE swój tekst i niczego nie kasuje z
    /// tego, co zostało wklejone przy pierwszej.
    func testDrugaWypowiedzNiePowtarzaPierwszej() {
        let differ = TextDiffer()

        // Pierwsza wypowiedź.
        _ = differ.diff(toHypothesis: "Halo")
        let plan1 = differ.diff(toHypothesis: "Halo test")
        XCTAssertEqual(plan1.insert, " test")
        XCTAssertEqual(plan1.deleteCount, 0)

        // Puszczenie skrótu i kolejne wciśnięcie: differ startuje od zera, a
        // silnik podaje już tylko świeżą hipotezę.
        differ.reset()

        let plan2a = differ.diff(toHypothesis: "druga")
        XCTAssertEqual(plan2a.insert, "druga")
        XCTAssertEqual(plan2a.deleteCount, 0, "nowa wypowiedź nie kasuje wklejonego wcześniej tekstu")

        let plan2b = differ.diff(toHypothesis: "druga wypowiedź")
        XCTAssertEqual(plan2b.insert, " wypowiedź")
        XCTAssertEqual(plan2b.deleteCount, 0)
        XCTAssertFalse(differ.displayedText.contains("Halo"), "pierwsza wypowiedź nie może wrócić w drugiej")
    }

    /// Poprawka wsteczna WEWNĄTRZ jednej wypowiedzi ma nadal działać — to jest
    /// właśnie to, czego stare porównanie prefiksu nie przeżywało.
    func testPoprawkaWstecznaWJednejWypowiedziDziala() {
        let differ = TextDiffer()

        _ = differ.diff(toHypothesis: "pierwsze zdanie")
        let plan = differ.diff(toHypothesis: "pierwsza zdanie")

        XCTAssertGreaterThan(plan.deleteCount, 0, "whisper poprawił słowo, differ musi je nadpisać")
        XCTAssertEqual(differ.displayedText, "pierwsza zdanie")
    }

    /// Pusta wypowiedź (stuknięcie skrótu bez mowy) nie zostawia śladu.
    func testPustaWypowiedzNicNieWstawia() {
        let differ = TextDiffer()
        _ = differ.diff(toHypothesis: "coś")
        differ.reset()

        let plan = differ.diff(toHypothesis: "")

        XCTAssertEqual(plan.insert, "")
        XCTAssertEqual(plan.deleteCount, 0)
    }
}
