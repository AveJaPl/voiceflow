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

    /// ŚWIADOMY brak parytetu z Pythonem (patrz doc-comment `formatDuration`):
    /// poniżej godziny pokazujemy sekundy, bo pojedyncze dyktowanie trwa
    /// sekundy i „0 min"/„1 min" nie mówiło nic.
    func testFormatDurationPokazujeSekundy() {
        XCTAssertEqual(StatsLib.formatDuration(0), "0 s")
        XCTAssertEqual(StatsLib.formatDuration(7.4), "7 s")
        XCTAssertEqual(StatsLib.formatDuration(59), "59 s")
        XCTAssertEqual(StatsLib.formatDuration(60), "1 min")
        XCTAssertEqual(StatsLib.formatDuration(72), "1 min 12 s")
        XCTAssertEqual(StatsLib.formatDuration(125), "2 min 5 s")
        XCTAssertEqual(StatsLib.formatDuration(600), "10 min")
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

    func testNajdluzszaSeriaZnajdujePrzeszlyRekord() {
        // Dziś + wczoraj (seria 2) oraz starsza seria 3 dni pod rząd.
        let notes = [
            note("a", daysAgo: 0), note("a", daysAgo: 1),
            note("a", daysAgo: 10), note("a", daysAgo: 11), note("a", daysAgo: 12),
        ]
        XCTAssertEqual(StatsLib.currentStreak(notes), 2)
        XCTAssertEqual(StatsLib.longestStreak(notes), 3)
    }

    func testTempoSlowNaMinute() {
        // 30 słów w 15 sekund mówienia = 120 słów na minutę.
        let text = Array(repeating: "słowo", count: 30).joined(separator: " ")
        XCTAssertEqual(StatsLib.wordsPerMinute([note(text, daysAgo: 0, duration: 15)]), 120, accuracy: 0.01)
        XCTAssertEqual(StatsLib.wordsPerMinute([]), 0)
    }

    func testPoprawkiLiczaSlowaSpozaWspolnegoPodciagu() {
        // Formatter dodał przecinek do „dobry" i zamienił „w" na nic: 1 token inny.
        XCTAssertEqual(StatsLib.fixCount(raw: "dzień dobry chciałbym", final: "Dzień dobry, chciałbym"), 2)
        XCTAssertEqual(StatsLib.fixCount(raw: "bez zmian", final: "bez zmian"), 0)
        // Stara historia bez tekstu surowego = zero poprawek, nie sto procent.
        XCTAssertEqual(StatsLib.fixCount(raw: "", final: "cokolwiek tutaj"), 0)
    }

    func testUdzialyAplikacjiSumujaSieISortuja() {
        let notes = [
            Note(finalText: "raz dwa trzy", rawText: "", targetBundleID: "com.apple.Terminal", duration: 1),
            Note(finalText: "raz", rawText: "", targetBundleID: nil, duration: 1),
        ]
        let shares = StatsLib.appWordShares(notes)
        XCTAssertEqual(shares.map { $0.bundleID }, ["com.apple.Terminal", StatsLib.unknownAppBundleID])
        XCTAssertEqual(shares.map { $0.words }, [3, 1])
        XCTAssertEqual(shares.map { $0.share }, [75, 25])
    }

    func testSzeregiTygodnioweIMiesieczneSaGesteIKonczaSieTeraz() {
        let notes = [note("jedno słowo tu", daysAgo: 0)]
        let weekly = StatsLib.weeklySeries(notes, weeks: 4)
        XCTAssertEqual(weekly.count, 4)
        XCTAssertEqual(weekly.last?.words, 3)
        XCTAssertEqual(weekly.dropLast().map { $0.words }, [0, 0, 0])
        let monthly = StatsLib.monthlySeries(notes, months: 3)
        XCTAssertEqual(monthly.count, 3)
        XCTAssertEqual(monthly.last?.words, 3)
    }

    func testSeriaLiczyTylkoDniPodRzad() {
        let ciagle = [note("a", daysAgo: 0), note("b", daysAgo: 1), note("c", daysAgo: 2)]
        XCTAssertEqual(StatsLib.currentStreak(ciagle), 3)

        let zPrzerwa = [note("a", daysAgo: 0), note("c", daysAgo: 2)]
        XCTAssertEqual(StatsLib.currentStreak(zPrzerwa), 1, "przerwa kończy serię")

        XCTAssertEqual(StatsLib.currentStreak([note("a", daysAgo: 1)]), 0, "wczoraj to jeszcze nie seria")
    }
}
