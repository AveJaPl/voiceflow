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

    /// „2 godz. 5 min" / „5 min" — jak `format_duration` w Pythonie.
    static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours) godz. \(minutes) min" }
        if hours > 0 { return "\(hours) godz." }
        return "\(minutes) min"
    }
}
