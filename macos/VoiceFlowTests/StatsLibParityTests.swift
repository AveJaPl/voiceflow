import XCTest
@testable import VoiceFlow

/// Zgodność `StatsLib` (Swift) z `src/voiceflow/statlib.py` (Python).
///
/// Ta sama historia musi dawać te same liczby na Macu, Linuksie i Windowsie —
/// inaczej „łącznie słów" znaczy co innego zależnie od tego, gdzie patrzysz.
/// Wartości oczekiwane niżej NIE są wymyślone: zostały wyliczone realnym
/// uruchomieniem funkcji z `statlib.py` i wklejone tutaj jako punkt odniesienia.
/// Jeśli któraś strona się zmieni, ten test upadnie i to jest jego cała rola.
final class StatsLibParityTests: XCTestCase {

    func testCompactNumberJakWPythonie() {
        XCTAssertEqual(StatsLib.compactNumber(0), "0")
        XCTAssertEqual(StatsLib.compactNumber(999), "999")
        XCTAssertEqual(StatsLib.compactNumber(1_000), "1 k")
        XCTAssertEqual(StatsLib.compactNumber(1_600), "1,6 k")
        XCTAssertEqual(StatsLib.compactNumber(12_345), "12,3 k")
        // Granica pasma: 999 499 to jeszcze tysiące, 999 500 zaokrągla się już
        // do miliona — zamiast mylącego „1 000 k".
        XCTAssertEqual(StatsLib.compactNumber(999_499), "999 k")
        XCTAssertEqual(StatsLib.compactNumber(999_500), "1 mln")
        XCTAssertEqual(StatsLib.compactNumber(1_234_567), "1,2 mln")
        XCTAssertEqual(StatsLib.compactNumber(-1_500), "−1,5 k", "minus typograficzny, nie łącznik")
    }

    func testFormatDurationJakWPythonie() {
        XCTAssertEqual(StatsLib.formatDuration(0), "0 min")
        XCTAssertEqual(StatsLib.formatDuration(59), "1 min")
        XCTAssertEqual(StatsLib.formatDuration(60), "1 min")
        XCTAssertEqual(StatsLib.formatDuration(3_600), "1 godz.")
        XCTAssertEqual(StatsLib.formatDuration(3_660), "1 godz. 1 min")
        XCTAssertEqual(StatsLib.formatDuration(7_325), "2 godz. 2 min")
    }

    func testProgiKwantyliJakWPythonie() {
        let thresholds = StatsLib.quantileThresholds([0, 5, 10, 15, 20, 0, 100])

        XCTAssertEqual(thresholds.q1, 10)
        XCTAssertEqual(thresholds.q2, 15)
        XCTAssertEqual(thresholds.q3, 20)

        let levels = [0, 5, 10, 15, 20, 100].map {
            StatsLib.activityLevel($0, thresholds: thresholds)
        }
        XCTAssertEqual(levels, [0, 1, 1, 2, 3, 4])
    }

    func testProgiZSamychZerRownajaSieZeru() {
        let thresholds = StatsLib.quantileThresholds([0, 0, 0])

        XCTAssertEqual(thresholds.q1, 0)
        XCTAssertEqual(StatsLib.activityLevel(0, thresholds: thresholds), 0)
    }

    // MARK: - Agregacja

    private func note(_ text: String, daysAgo: Int, duration: Double = 1) -> Note {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return Note(
            createdAt: day,
            finalText: text,
            rawText: text,
            targetBundleID: nil,
            duration: duration
        )
    }

    func testSumySaLiczoneJakPrzySplitcie() {
        let notes = [
            note("raz dwa trzy", daysAgo: 0, duration: 4),
            note("cztery  pięć", daysAgo: 0, duration: 6),
        ]

        let totals = StatsLib.totals(notes)

        XCTAssertEqual(totals.words, 5, "podwójna spacja nie tworzy pustego słowa")
        XCTAssertEqual(totals.dictations, 2)
        XCTAssertEqual(totals.audioSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(totals.averageWords, 2.5, accuracy: 0.001)
    }

    func testSzeregDziennyJestGestyIKonczySieDzisiaj() {
        let notes = [note("jedno słowo", daysAgo: 2), note("dziś", daysAgo: 0)]

        let series = StatsLib.dailySeries(notes, days: 3)

        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.map { $0.words }, [2, 0, 1], "dzień bez dyktowania zostaje jako zero")
    }

    func testSeriaLiczyTylkoDniPodRzad() {
        let ciagle = [note("a", daysAgo: 0), note("b", daysAgo: 1), note("c", daysAgo: 2)]
        XCTAssertEqual(StatsLib.currentStreak(ciagle), 3)

        let zPrzerwa = [note("a", daysAgo: 0), note("c", daysAgo: 2)]
        XCTAssertEqual(StatsLib.currentStreak(zPrzerwa), 1, "przerwa kończy serię")

        XCTAssertEqual(StatsLib.currentStreak([note("a", daysAgo: 1)]), 0, "wczoraj to jeszcze nie seria")
    }
}
