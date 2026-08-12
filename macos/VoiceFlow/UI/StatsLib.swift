import Foundation

/// Port `src/voiceflow/statlib.py` na Swifta — te same reguły liczenia, żeby
/// ta sama historia dawała te same liczby na każdej platformie.
///
/// Wszystko tutaj jest czyste: żadnego wejścia/wyjścia i żadnego zegara poza
/// wstrzykiwanym `today`. Dzięki temu ekran statystyk da się przetestować bez
/// pliku historii — dokładnie jak po stronie Pythona.
enum StatsLib {

    struct Totals: Equatable {
        var words: Int = 0
        var dictations: Int = 0
        var audioSeconds: Double = 0
        var averageWords: Double = 0
    }

    /// Liczba słów tak samo jak `text.split()` w Pythonie: dowolny biały znak
    /// rozdziela, puste ciągi nie liczą się jako słowo.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func totals(_ notes: [Note]) -> Totals {
        var result = Totals()
        result.dictations = notes.count
        for note in notes {
            result.words += wordCount(note.finalText)
            result.audioSeconds += max(0, note.duration)
        }
        result.averageWords = notes.isEmpty ? 0 : Double(result.words) / Double(notes.count)
        return result
    }

    /// Suma słów w każdym dniu kalendarzowym, w strefie lokalnej.
    static func dailyWordTotals(
        _ notes: [Note], calendar: Calendar = .current
    ) -> [Date: Int] {
        var totals: [Date: Int] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.createdAt)
            totals[day, default: 0] += wordCount(note.finalText)
        }
        return totals
    }

    /// Gęsty szereg dzienny kończący się dzisiaj, od najstarszego. Dni bez
    /// dyktowania są w nim jawnie, z zerem — wykres ma pokazywać przerwy,
    /// a nie ściskać oś tak, jakby ich nie było.
    static func dailySeries(
        _ notes: [Note], days: Int, today: Date = Date(), calendar: Calendar = .current
    ) -> [(day: Date, words: Int)] {
        guard days > 0 else { return [] }
        let end = calendar.startOfDay(for: today)
        let totals = dailyWordTotals(notes, calendar: calendar)
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - (days - 1), to: end) else {
                return nil
            }
            return (day, totals[day] ?? 0)
        }
    }

    /// Suma słów w każdej godzinie dzisiejszego dnia (0–23).
    static func hourlyWordTotals(
        _ notes: [Note], today: Date = Date(), calendar: Calendar = .current
    ) -> [Int] {
        var totals = [Int](repeating: 0, count: 24)
        let day = calendar.startOfDay(for: today)
        for note in notes where calendar.startOfDay(for: note.createdAt) == day {
            let hour = calendar.component(.hour, from: note.createdAt)
            if hour >= 0, hour < 24 {
                totals[hour] += wordCount(note.finalText)
            }
        }
        return totals
    }

    /// Liczba kolejnych dni z dyktowaniem, licząc wstecz od dzisiaj.
    static func currentStreak(
        _ notes: [Note], today: Date = Date(), calendar: Calendar = .current
    ) -> Int {
        let active = Set(dailyWordTotals(notes, calendar: calendar).filter { $0.value > 0 }.keys)
        var day = calendar.startOfDay(for: today)
        var streak = 0
        while active.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// Najdłuższa seria kolejnych dni z dyktowaniem w całej historii.
    static func longestStreak(_ notes: [Note], calendar: Calendar = .current) -> Int {
        let active = dailyWordTotals(notes, calendar: calendar)
            .filter { $0.value > 0 }
            .keys.sorted()
        var longest = 0
        var current = 0
        var previous: Date?
        for day in active {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: day) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            previous = day
        }
        return longest
    }

    /// Tempo mówienia: wszystkie słowa przez cały czas mówienia. Zero, gdy
    /// historia nie ma ani sekundy audio — lepsze niż dzielenie przez zero
    /// przebrane za nieskończone tempo.
    static func wordsPerMinute(_ notes: [Note]) -> Double {
        let summary = totals(notes)
        guard summary.audioSeconds > 0 else { return 0 }
        return Double(summary.words) / (summary.audioSeconds / 60)
    }

    /// Ile słów Formatter zmienił między surowym ASR a tekstem końcowym —
    /// odpowiednik „fixes made by Flow". Miara: słowa spoza najdłuższego
    /// wspólnego podciągu (LCS) po stronie tekstu końcowego; porównanie bez
    /// wielkości liter i interpunkcji liczyłoby każdy przecinek jak poprawkę
    /// zdania, więc porównujemy tokeny dosłownie — interpunkcja to też praca
    /// Formattera i właśnie ją chcemy tu widzieć.
    static func fixCount(raw: String, final: String) -> Int {
        let a = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let b = final.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Bez tekstu surowego (stara historia, wpisy z Linuksa bez `raw`) nie ma
        // do czego porównywać — zero poprawek, nie „wszystko poprawione".
        guard !a.isEmpty else { return 0 }
        guard !b.isEmpty else { return 0 }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return b.count - table[a.count][b.count]
    }

    static func totalFixes(_ notes: [Note]) -> Int {
        notes.reduce(0) { $0 + fixCount(raw: $1.rawText, final: $1.finalText) }
    }

    struct AppShare: Equatable, Identifiable {
        let bundleID: String
        let words: Int
        /// Udział w słowach całej historii, 0–100.
        let share: Int
        var id: String { bundleID }
    }

    /// Dokąd trafiają słowa — suma per aplikacja docelowa, malejąco. Dyktowania
    /// bez znanego celu (nieudane wstrzyknięcie, stara historia) zbierają się
    /// pod jednym wpisem, żeby procenty zawsze sumowały się do całości.
    static let unknownAppBundleID = "—"

    static func appWordShares(_ notes: [Note]) -> [AppShare] {
        var perApp: [String: Int] = [:]
        for note in notes {
            perApp[note.targetBundleID ?? unknownAppBundleID, default: 0] += wordCount(note.finalText)
        }
        let total = perApp.values.reduce(0, +)
        guard total > 0 else { return [] }
        return perApp
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { AppShare(
                bundleID: $0.key,
                words: $0.value,
                share: Int((Double($0.value) * 100 / Double(total)).rounded(.toNearestOrEven))
            ) }
    }

    /// Gęsty szereg tygodniowy (kolumna = tydzień zaczynający się w poniedziałek
    /// lokalnego kalendarza), kończący się bieżącym tygodniem.
    static func weeklySeries(
        _ notes: [Note], weeks: Int, today: Date = Date(), calendar: Calendar = .current
    ) -> [(start: Date, words: Int)] {
        bucketSeries(notes, count: weeks, component: .weekOfYear, today: today, calendar: calendar)
    }

    /// Gęsty szereg miesięczny kończący się bieżącym miesiącem.
    static func monthlySeries(
        _ notes: [Note], months: Int, today: Date = Date(), calendar: Calendar = .current
    ) -> [(start: Date, words: Int)] {
        bucketSeries(notes, count: months, component: .month, today: today, calendar: calendar)
    }

    private static func bucketSeries(
        _ notes: [Note], count: Int, component: Calendar.Component, today: Date, calendar: Calendar
    ) -> [(start: Date, words: Int)] {
        guard count > 0 else { return [] }
        let interval: Calendar.Component = component == .month ? .month : .weekOfYear
        guard let currentStart = calendar.dateInterval(of: interval, for: today)?.start else { return [] }
        var totals: [Date: Int] = [:]
        for note in notes {
            guard let start = calendar.dateInterval(of: interval, for: note.createdAt)?.start else { continue }
            totals[start, default: 0] += wordCount(note.finalText)
        }
        return (0..<count).compactMap { offset in
            guard let start = calendar.date(byAdding: interval, value: offset - (count - 1), to: currentStart) else {
                return nil
            }
            return (start, totals[start] ?? 0)
        }
    }

    /// Progi 25/50/75 percentyla metodą najbliższej rangi — liczone TYLKO z dni
    /// niezerowych, żeby długa przerwa nie spłaszczyła całej skali do zera.
    static func quantileThresholds(_ values: [Int]) -> (q1: Int, q2: Int, q3: Int) {
        let ordered = values.filter { $0 > 0 }.sorted()
        guard !ordered.isEmpty else { return (0, 0, 0) }
        func percentile(_ fraction: Double) -> Int {
            let index = max(0, Int((fraction * Double(ordered.count)).rounded(.up)) - 1)
            return ordered[min(index, ordered.count - 1)]
        }
        return (percentile(0.25), percentile(0.50), percentile(0.75))
    }

    /// Pięciostopniowa skala aktywności (0–4) dla kalendarza.
    static func activityLevel(_ value: Int, thresholds: (q1: Int, q2: Int, q3: Int)) -> Int {
        guard value > 0 else { return 0 }
        if value <= thresholds.q1 { return 1 }
        if value <= thresholds.q2 { return 2 }
        if value <= thresholds.q3 { return 3 }
        return 4
    }

    // MARK: - Formatowanie (identyczne z Pythonem, łącznie z przecinkiem)

    /// „1,6 k", „999 k", „1,2 mln" — zwięźle, po polsku, maksimum trzy cyfry.
    static func compactNumber(_ value: Int) -> String {
        let sign = value < 0 ? "−" : ""
        let magnitude = abs(value)
        if magnitude < 1_000 { return "\(sign)\(magnitude)" }
        if magnitude < 999_500 {
            let scaled = Double(magnitude) / 1_000
            return "\(sign)\(scaledString(scaled)) k"
        }
        let scaled = Double(magnitude) / 1_000_000
        return "\(sign)\(scaledString(scaled)) mln"
    }

    private static func scaledString(_ value: Double) -> String {
        let decimals = value < 100 ? 1 : 0
        var rendered = String(format: "%.\(decimals)f", value)
        if decimals > 0, rendered.hasSuffix("0") {
            rendered.removeLast()
            if rendered.hasSuffix(".") { rendered.removeLast() }
        }
        return rendered.replacingOccurrences(of: ".", with: ",")
    }

    /// „42 s" / „1 min 12 s" / „2 godz. 5 min" — ŚWIADOME odejście od parytetu
    /// z Pythonem (`format_duration` zaokrągla do minut): pojedyncze dyktowanie
    /// trwa sekundy, więc „0 min" i „1 min" mówiły dokładnie nic. Sekundy
    /// znikają dopiero od godziny w górę, gdzie już naprawdę nie mają znaczenia.
    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0, minutes > 0 { return "\(hours) godz. \(minutes) min" }
        if hours > 0 { return "\(hours) godz." }
        if rest > 0 { return "\(minutes) min \(rest) s" }
        return "\(minutes) min"
    }
}
