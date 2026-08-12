import XCTest
@testable import VoiceFlow

/// Gramatyka trybu nasłuchu. Wszystkie warianty słów niżej to REALNE wyjścia
/// whispera dla tych samych wypowiedzi — dopasowanie znak w znak dawałoby
/// funkcję działającą co drugi raz.
final class VoiceCommandRouterTests: XCTestCase {

    private func router() -> VoiceCommandRouter {
        VoiceCommandRouter(targets: ["pierwszy", "drugi", "trzeci", "claude backend"])
    }

    func testPelnyPrzebiegOdKomendyDoWklejenia() {
        var r = router()
        XCTAssertEqual(r.consume("terminal pierwszy nasłuchuj"), .startedCollecting(target: "pierwszy"))
        XCTAssertEqual(
            r.consume("napisz testy do modułu płatności"),
            .collecting(target: "pierwszy", text: "napisz testy do modułu płatności")
        )
        XCTAssertEqual(
            r.consume("i odpal je w trybie watch"),
            .collecting(target: "pierwszy", text: "napisz testy do modułu płatności i odpal je w trybie watch")
        )
        XCTAssertEqual(
            r.consume("koniec terminal pierwszy"),
            .commit(target: "pierwszy", text: "napisz testy do modułu płatności i odpal je w trybie watch")
        )
        // Po wklejeniu wracamy do bezczynności — zwykłe zdanie nic nie robi.
        XCTAssertEqual(r.consume("a teraz rozmawiam sobie z kimś"), .ignore)
    }

    func testPrzekreconeWariantyKomendyDzialaja() {
        for variant in ["terminal pierwszy nasluchuj", "Terminal pierwszy, nasłuchój.", "terminal pierwszy na słuchaj"] {
            var r = router()
            guard case .startedCollecting(let target) = r.consume(variant) else {
                return XCTFail("wariant nierozpoznany: \(variant)")
            }
            XCTAssertEqual(target, "pierwszy")
        }
    }

    func testLiczebnikGlownyZamiastPorzadkowego() {
        // Whisper na żywo oddał „terminal pierwszy" jako „Derminal jeden".
        var r = router()
        XCTAssertEqual(r.consume("terminal jeden nasłuchuj"), .startedCollecting(target: "pierwszy"))
        var r2 = router()
        XCTAssertEqual(r2.consume("terminal dwa słuchaj"), .startedCollecting(target: "drugi"))
    }

    /// DOSŁOWNE wyjścia whispera z żywego przebiegu 2026-08-12 dla jednej i tej
    /// samej wypowiedzi „terminal jeden nasłuchuj". Ten test istnieje po to,
    /// żeby nikt nigdy nie wrócił do porównywania całych słów.
    func testRealneWyjsciaWhisperaZLogu() {
        let realne = [
            "Ale nic nie widać. Terminal 1 na słuchanie.",
            "Terminal 1 na słuchaj",
            "- Terminal jeden, nasłuchuj.",
            "terminal 1 nasłuchiwanie",
        ]
        for fragment in realne {
            var r = router()
            guard case .startedCollecting(let target) = r.consume(fragment) else {
                return XCTFail("nierozpoznane realne wyjście whispera: \(fragment)")
            }
            XCTAssertEqual(target, "pierwszy")
        }
    }

    func testNakladajaceSieOknaNieDublujaSlow() {
        var r = router()
        _ = r.consume("terminal jeden nasłuchuj")
        _ = r.consume("napisz testy do modułu")
        // Następne okno zachodzi o 1,5 s, więc powtarza końcówkę poprzedniego.
        guard case .collecting(_, let text) = r.consume("do modułu płatności i odpal je") else {
            return XCTFail("brak zbierania")
        }
        XCTAssertEqual(text, "napisz testy do modułu płatności i odpal je")
    }

    func testGadanieBezKomendyNieUruchamiaZbierania() {
        var r = router()
        XCTAssertEqual(r.consume("dobra, to teraz zróbmy przerwę"), .ignore)
        XCTAssertEqual(r.consume("terminal wygląda dziwnie"), .ignore, "sama nazwa bez „nasłuchuj” to nie komenda")
        XCTAssertNil(r.activeTarget)
    }

    func testPodobneNazwyNieMylaSieZeSoba() {
        var r = router()
        XCTAssertEqual(r.consume("terminal trzeci nasłuchuj"), .startedCollecting(target: "trzeci"))
        XCTAssertEqual(r.activeTarget, "trzeci")
    }

    func testNazwaWielowyrazowa() {
        var r = router()
        XCTAssertEqual(r.consume("claude backend nasłuchuj"), .startedCollecting(target: "claude backend"))
    }

    func testAnulowanieZapominaPrompt() {
        var r = router()
        _ = r.consume("terminal drugi słuchaj")
        _ = r.consume("to jest jakiś prompt")
        XCTAssertEqual(r.consume("anuluj"), .cancelled(target: "drugi"))
        XCTAssertNil(r.activeTarget)
    }

    func testPustyPromptNieWklejaPustki() {
        var r = router()
        _ = r.consume("terminal pierwszy nasłuchuj")
        XCTAssertEqual(r.consume("koniec"), .cancelled(target: "pierwszy"),
                       "„nasłuchuj” i od razu „koniec” nie ma czego wkleić")
    }

    func testKomendaKonczacaMaPierwszenstwoNadTrescia() {
        var r = router()
        _ = r.consume("terminal pierwszy nasłuchuj")
        _ = r.consume("zrób refaktor")
        // Fragment zawiera nazwę celu, ale to KONIEC, nie nowy start.
        guard case .commit(let target, let text) = r.consume("wyślij terminal pierwszy") else {
            return XCTFail("koniec nierozpoznany")
        }
        XCTAssertEqual(target, "pierwszy")
        XCTAssertEqual(text, "zrób refaktor")
    }

    func testPrzeniesienieStanuPrzyOdswiezeniuNazw() {
        var r = router()
        _ = r.consume("terminal pierwszy nasłuchuj")
        _ = r.consume("pierwsza część promptu")
        // Okna się zmieniły — nowy router z tą samą listą przejmuje stan.
        var refreshed = VoiceCommandRouter(targets: ["pierwszy", "drugi"])
        refreshed.restore(from: r)
        XCTAssertEqual(
            refreshed.consume("koniec"),
            .commit(target: "pierwszy", text: "pierwsza część promptu")
        )
    }

    func testNormalizacjaZdejmujeDiakrytykiIInterpunkcje() {
        XCTAssertEqual(VoiceCommandRouter.normalize("Terminal PIERWSZY, nasłuchuj!"), "terminal pierwszy nasluchuj")
    }

    func testPodobienstwoNieLaczySlowOInnymZnaczeniu() {
        XCTAssertTrue(VoiceCommandRouter.similar("nasluchuj", "nasluchoj"))
        XCTAssertFalse(VoiceCommandRouter.similar("pierwszy", "czwarty"))
        XCTAssertFalse(VoiceCommandRouter.similar("drugi", "trzeci"))
    }
}
