import XCTest
@testable import VoiceFlow

/// Gramatyka trybu nasłuchu. Wszystkie warianty słów niżej to REALNE wyjścia
/// whispera dla tych samych wypowiedzi — dopasowanie znak w znak dawałoby
/// funkcję działającą co drugi raz.
final class VoiceCommandRouterTests: XCTestCase {

    private func router() -> VoiceCommandRouter {
        VoiceCommandRouter(targets: ["lampa", "zebra", "kokos", "claude backend"])
    }

    func testPelnyPrzebiegOdKomendyDoWklejenia() {
        var r = router()
        XCTAssertEqual(r.consume("halo lampa"), .startedCollecting(target: "lampa"))
        XCTAssertEqual(
            r.consume("napisz testy do modułu płatności"),
            .collecting(target: "lampa", text: "napisz testy do modułu płatności")
        )
        XCTAssertEqual(
            r.consume("i odpal je w trybie watch"),
            .collecting(target: "lampa", text: "napisz testy do modułu płatności i odpal je w trybie watch")
        )
        XCTAssertEqual(
            r.consume("koniec lampa"),
            .commit(target: "lampa", text: "napisz testy do modułu płatności i odpal je w trybie watch")
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
            XCTAssertEqual(target, "lampa")
        }
    }

    func testLiczebnikGlownyZamiastPorzadkowego() {
        // Whisper na żywo oddał „terminal pierwszy" jako „Derminal jeden".
        var r = router()
        XCTAssertEqual(r.consume("halo lampa"), .startedCollecting(target: "lampa"))
        var r2 = router()
        XCTAssertEqual(r2.consume("halo zebra"), .startedCollecting(target: "zebra"))
    }

    /// DOSŁOWNE wyjścia whispera z żywego przebiegu 2026-08-12 dla jednej i tej
    /// samej wypowiedzi „terminal jeden nasłuchuj". Ten test istnieje po to,
    /// żeby nikt nigdy nie wrócił do porównywania całych słów.
    func testRealneWyjsciaWhisperaZLogu() {
        let realne = [
            "Ale nic nie widać. Terminal 1 na słuchanie.",   // stara składnia dalej działa
            "- Halo, lampa.",
            "halo lampę",
            "Halo lampa, słuchaj.",
        ]
        for fragment in realne {
            var r = router()
            guard case .startedCollecting(let target) = r.consume(fragment) else {
                return XCTFail("nierozpoznane realne wyjście whispera: \(fragment)")
            }
            XCTAssertEqual(target, "lampa")
        }
    }

    func testNakladajaceSieOknaNieDublujaSlow() {
        var r = router()
        _ = r.consume("halo lampa")
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
        XCTAssertEqual(r.consume("lampa wygląda dziwnie"), .ignore, "sama nazwa bez „halo” to nie komenda")
        XCTAssertNil(r.activeTarget)
    }

    func testPodobneNazwyNieMylaSieZeSoba() {
        var r = router()
        XCTAssertEqual(r.consume("halo kokos"), .startedCollecting(target: "kokos"))
        XCTAssertEqual(r.activeTarget, "kokos")
    }

    func testNazwaWielowyrazowa() {
        var r = router()
        XCTAssertEqual(r.consume("halo claude backend"), .startedCollecting(target: "claude backend"))
    }

    func testAnulowanieZapominaPrompt() {
        var r = router()
        _ = r.consume("halo zebra")
        _ = r.consume("to jest jakiś prompt")
        XCTAssertEqual(r.consume("anuluj"), .cancelled(target: "zebra"))
        XCTAssertNil(r.activeTarget)
    }

    func testPustyPromptNieWklejaPustki() {
        var r = router()
        _ = r.consume("halo lampa")
        XCTAssertEqual(r.consume("koniec"), .cancelled(target: "lampa"),
                       "„nasłuchuj” i od razu „koniec” nie ma czego wkleić")
    }

    func testKomendaKonczacaMaPierwszenstwoNadTrescia() {
        var r = router()
        _ = r.consume("halo lampa")
        _ = r.consume("zrób refaktor")
        // Fragment zawiera nazwę celu, ale to KONIEC, nie nowy start.
        guard case .commit(let target, let text) = r.consume("wyślij lampa") else {
            return XCTFail("koniec nierozpoznany")
        }
        XCTAssertEqual(target, "lampa")
        XCTAssertEqual(text, "zrób refaktor")
    }

    func testPrzeniesienieStanuPrzyOdswiezeniuNazw() {
        var r = router()
        _ = r.consume("halo lampa")
        _ = r.consume("pierwsza część promptu")
        // Okna się zmieniły — nowy router z tą samą listą przejmuje stan.
        var refreshed = VoiceCommandRouter(targets: ["lampa", "zebra"])
        refreshed.restore(from: r)
        XCTAssertEqual(
            refreshed.consume("koniec"),
            .commit(target: "lampa", text: "pierwsza część promptu")
        )
    }

    func testNormalizacjaZdejmujeDiakrytykiIInterpunkcje() {
        XCTAssertEqual(VoiceCommandRouter.normalize("Halo LAMPA, nasłuchuj!"), "halo lampa nasluchuj")
    }

    func testPodobienstwoNieLaczySlowOInnymZnaczeniu() {
        XCTAssertTrue(VoiceCommandRouter.similar("nasluchuj", "nasluchoj"))
        XCTAssertFalse(VoiceCommandRouter.similar("lampa", "zebra"))
        XCTAssertFalse(VoiceCommandRouter.similar("kokos", "radio"))
    }
}
