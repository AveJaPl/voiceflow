import XCTest
@testable import VoiceFlow

/// Filtr zmyślonych pożegnań. Najważniejsze są tu testy NEGATYWNE: funkcja,
/// która zjada ludziom prawdziwe słowa, jest gorsza niż halucynacja zostawiona
/// w tekście.
final class HallucinationFilterTests: XCTestCase {

    private func segment(_ text: String, noSpeech: Float = 0.9, logProb: Float = -1.2) -> HallucinationFilter.Segment {
        HallucinationFilter.Segment(text: text, noSpeechProbability: noSpeech, averageLogProbability: logProb)
    }

    func testUcinaPozegnanieDopisaneDoCiszy() {
        let kept = HallucinationFilter.dropTrailingHallucinations([
            segment("Zrób refaktor tego modułu.", noSpeech: 0.02, logProb: -0.2),
            segment(" Dziękuję za oglądanie."),
        ])
        XCTAssertEqual(kept.map(\.text), ["Zrób refaktor tego modułu."])
    }

    /// Ta padła na żywo 2026-08-14: cała wypowiedź wróciła jako komunikat o
    /// tłumaczeniu, którego nikt nie wypowiedział.
    func testUcinaHalucynacjeZmierzonaNaZywo() {
        XCTAssertTrue(HallucinationFilter.isPureHallucination(
            "[tłumaczenie na język ukraińskim]", noSpeechProbability: 0.8, averageLogProbability: -0.9
        ))
    }

    /// Wypowiedziane „dziękuję" ma metadane pewnego segmentu — zostaje.
    func testPrawdziwePodziekowanieZostaje() {
        let segments = [
            segment("Wyślij to do klienta.", noSpeech: 0.01, logProb: -0.2),
            segment("Dziękuję.", noSpeech: 0.05, logProb: -0.25),
        ]
        XCTAssertEqual(HallucinationFilter.dropTrailingHallucinations(segments).count, 2)
    }

    /// Fraza z listy w ŚRODKU wypowiedzi nie jest pożegnaniem — ucinamy tylko
    /// z końca, inaczej znikałyby kawałki zdania.
    func testFrazaWSrodkuNieJestUcinana() {
        let segments = [
            segment("Dziękuję.", noSpeech: 0.9, logProb: -1.5),
            segment("A teraz zrób to jeszcze raz.", noSpeech: 0.01, logProb: -0.2),
        ]
        XCTAssertEqual(HallucinationFilter.dropTrailingHallucinations(segments).count, 2)
    }

    /// Kilka doklejonych pożegnań pod rząd — model potrafi dopisać dwa.
    func testUcinaKilkaPozegnanPodRzad() {
        let kept = HallucinationFilter.dropTrailingHallucinations([
            segment("Prompt do Clauda.", noSpeech: 0.01, logProb: -0.2),
            segment("Dziękuję za oglądanie."),
            segment("Do zobaczenia."),
        ])
        XCTAssertEqual(kept.count, 1)
    }

    func testNormalizacjaZdejmujeDiakrytykiIInterpunkcje() {
        XCTAssertEqual(HallucinationFilter.normalize("Dziękuję za oglądanie!"), "dziekuje za ogladanie")
        XCTAssertEqual(
            HallucinationFilter.normalize("Napisy stworzone przez społeczność Amara.org"),
            "napisy stworzone przez spolecznosc amara org"
        )
    }

    /// Zwykłe zdanie nie ma prawa zniknąć, choćby model był go niepewny.
    func testNiepewneZwykleZdanieZostaje() {
        let segments = [segment("Zrób to jeszcze raz, ale wolniej.", noSpeech: 0.95, logProb: -2)]
        XCTAssertEqual(HallucinationFilter.dropTrailingHallucinations(segments).count, 1)
    }
}
