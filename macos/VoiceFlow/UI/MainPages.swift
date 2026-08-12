import SwiftUI
import AppKit

/// Historia oraz panel statystyk, których Mac dotąd nie miał w tej formie.
/// Układ i teksty przepisane z `app/voiceflow_app/pages/history.py` i `stats.py`.
/// Statystyki nie są osobną stroną — `StatsInsights` jest dolną częścią Przeglądu.

// MARK: - Historia

struct HistoryPage: View {
    @ObservedObject var model: AppUIModel

    @State private var query: String = ""
    @State private var expanded: Set<UUID> = []

    private var filtered: [Note] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.notes }
        return model.notes.filter { $0.finalText.lowercased().contains(needle) }
    }

    var body: some View {
        VFPageHeader(
            title: "Historia",
            subtitle: "Wyszukuj, rozwijaj i ponownie kopiuj lokalne dyktowania."
        )

        HStack(spacing: VF.Space.x8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(VF.Color.faint)
            TextField("Szukaj w historii", text: $query)
                .textFieldStyle(.plain)
                .font(VF.Font.body(13))
                .foregroundStyle(VF.Color.text)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VF.Color.faint)
            }
        }
        .padding(.horizontal, VF.Space.x12)
        .padding(.vertical, VF.Space.x8)
        .background(
            RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                .fill(VF.Color.surfaceRaised)
        )

        if filtered.isEmpty {
            VStack(alignment: .leading, spacing: VF.Space.x4) {
                Text(query.isEmpty ? "Historia jest pusta." : "Nic nie pasuje do \"\(query)\"")
                    .font(VF.Font.body(13))
                    .foregroundStyle(VF.Color.text)
                if query.isEmpty {
                    Text("Pierwsze dyktowanie pojawi się tutaj.")
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.faint)
                }
            }
            .vfCard()
        } else {
            VStack(spacing: VF.Space.x8) {
                ForEach(filtered) { note in
                    HistoryRow(
                        note: note,
                        isExpanded: expanded.contains(note.id),
                        toggle: {
                            if expanded.contains(note.id) {
                                expanded.remove(note.id)
                            } else {
                                expanded.insert(note.id)
                            }
                        },
                        delete: { model.delete(note.id) }
                    )
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let note: Note
    let isExpanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VF.Space.x8) {
            HStack(alignment: .top, spacing: VF.Space.x12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.finalText)
                        .font(VF.Font.body(13))
                        .foregroundStyle(VF.Color.text)
                        .lineLimit(isExpanded ? nil : 2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: VF.Space.x8) {
                        Text(note.createdAt, style: .date)
                        Text(note.createdAt, style: .time)
                        Text("·")
                        Text("\(StatsLib.wordCount(note.finalText)) słów")
                        Text("·")
                        Text(StatsLib.formatDuration(note.duration))
                        if !note.injected {
                            Text("· nie trafiło do aplikacji")
                                .foregroundStyle(VF.Color.recording)
                        }
                    }
                    .font(VF.Font.body(11))
                    .foregroundStyle(VF.Color.faint)
                }
                Spacer(minLength: VF.Space.x8)
                HStack(spacing: VF.Space.x4) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.finalText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VF.Color.muted)
                    .help("Kopiuj")

                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VF.Color.muted)
                    .help(isExpanded ? "Zwiń" : "Rozwiń")

                    Button(action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VF.Color.faint)
                    .help("Usuń")
                }
            }
        }
        .vfCard(padding: VF.Space.x12)
    }
}

// MARK: - Statystyki

/// Zakres wykresu słów — dzienny, tygodniowy albo miesięczny, jak w panelach
/// „Insights" komercyjnych dyktafonów.
enum StatsRange: String, CaseIterable, Identifiable {
    case daily, weekly, monthly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: "31 dni"
        case .weekly: "26 tygodni"
        case .monthly: "12 miesięcy"
        }
    }
}

/// Dolna część Przeglądu: liczby, wykresy i kalendarz aktywności. Osobny widok,
/// bo trzyma własny stan (zakres wykresu, przeliczone podsumowanie) i nie ma
/// nagłówka strony — tytuł nosi Przegląd.
struct StatsInsights: View {
    @ObservedObject var model: AppUIModel
    @State private var range: StatsRange = .daily

    /// Wszystkie liczby strony w jednym przebiegu po historii — liczone raz na
    /// zmianę `model.notes`, nie przy każdym przerysowaniu (LCS w `totalFixes`
    /// jest najdroższą pozycją i nie ma prawa liczyć się per klatka).
    private struct Summary {
        var totals = StatsLib.Totals()
        var wordsPerMinute: Double = 0
        var fixes = 0
        var currentStreak = 0
        var longestStreak = 0
        var appShares: [StatsLib.AppShare] = []
        var bestDay: (day: Date, words: Int)?

        init(_ notes: [Note]) {
            totals = StatsLib.totals(notes)
            wordsPerMinute = StatsLib.wordsPerMinute(notes)
            fixes = StatsLib.totalFixes(notes)
            currentStreak = StatsLib.currentStreak(notes)
            longestStreak = StatsLib.longestStreak(notes)
            appShares = StatsLib.appWordShares(notes)
            bestDay = StatsLib.bestDay(notes)
        }
    }

    @State private var summary = Summary([])

    private var series: [Int] {
        switch range {
        case .daily: StatsLib.dailySeries(model.notes, days: 31).map { $0.words }
        case .weekly: StatsLib.weeklySeries(model.notes, weeks: 26).map { $0.words }
        case .monthly: StatsLib.monthlySeries(model.notes, months: 12).map { $0.words }
        }
    }

    private var activity: [(day: Date, words: Int)] { StatsLib.dailySeries(model.notes, days: 182) }

    var body: some View {
        // Odstęp taki sam jak między sekcjami Przeglądu — panel ma wyglądać jak
        // dalszy ciąg strony, nie jak wklejony blok.
        VStack(alignment: .leading, spacing: VF.Space.x24) {
            if model.notes.isEmpty {
                Text("Brak statystyk. Pierwsze dyktowanie uruchomi podsumowania i wykresy.")
                    .font(VF.Font.body(13))
                    .foregroundStyle(VF.Color.muted)
                    .vfCard()
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { summary = Summary(model.notes) }
        .onChange(of: model.notes) { summary = Summary(model.notes) }
    }

    /// Kafelki w siatce, nie w jednym rzędzie: przy sześciu pozycjach i oknie
    /// zwężonym do minimum rząd ściskał liczby do nieczytelnych słupków, a każda
    /// karta łamała podpis w innym miejscu — stąd „rozjechane".
    /// Trzy kolumny na sztywno: sześć kafelków układa się wtedy w pełne dwa
    /// rzędy przy każdej szerokości okna, zamiast zostawiać w drugim rzędzie
    /// dwie karty i dziurę.
    private static let statColumns = Array(
        repeating: GridItem(.flexible(), spacing: VF.Space.x12, alignment: .top),
        count: 3
    )

    @ViewBuilder private var content: some View {
        LazyVGrid(columns: Self.statColumns, alignment: .leading, spacing: VF.Space.x12) {
            VFStatCard(
                label: "Słów na minutę",
                value: summary.wordsPerMinute > 0
                    ? String(format: "%.0f", summary.wordsPerMinute.rounded())
                    : "—",
                trend: "tempo mówienia z całej historii"
            )
            VFStatCard(
                label: "Łącznie słów",
                value: StatsLib.compactNumber(summary.totals.words),
                trend: "\(StatsLib.compactNumber(summary.totals.dictations)) dyktowań"
            )
            VFStatCard(
                label: "Czas mówienia",
                value: StatsLib.formatDuration(summary.totals.audioSeconds),
                trend: "średnio \(Int(summary.totals.averageWords.rounded())) słów na dyktowanie"
            )
            VFStatCard(
                label: "Poprawki VoiceFlow",
                value: StatsLib.compactNumber(summary.fixes),
                trend: "słowa zmienione między ASR a tekstem"
            )
            VFStatCard(
                label: "Najdłuższy dzień",
                value: summary.bestDay.map { StatsLib.compactNumber($0.words) } ?? "—",
                suffix: summary.bestDay == nil ? nil : "słów",
                trend: summary.bestDay.map { "rekord z \(Self.dayLabel($0.day))" } ?? "brak dnia z dyktowaniem"
            )
            VFStatCard(
                label: "Seria dni",
                value: "\(summary.currentStreak)",
                suffix: polishDays(summary.currentStreak),
                trend: "najdłuższa: \(summary.longestStreak) \(polishDays(summary.longestStreak))"
            )
        }

        VFSection(title: "Słowa w czasie") {
            VFSegmented(
                options: StatsRange.allCases.map { (value: $0, label: $0.label) },
                selection: $range
            )
            VFBarChart(values: series, height: 140)
        }

        VFSection(
            title: "Dokąd trafiają słowa",
            subtitle: "Udział aplikacji docelowych we wszystkich podyktowanych słowach."
        ) {
            if donutSegments.isEmpty {
                Text("Brak danych o aplikacjach docelowych.")
                    .font(VF.Font.body(12))
                    .foregroundStyle(VF.Color.faint)
            } else {
                VFDonutChart(
                    segments: donutSegments,
                    centerValue: StatsLib.compactNumber(summary.totals.words),
                    centerCaption: "słów łącznie"
                )
            }
        }

        VFSection(
            title: "Aktywność · 26 tygodni",
            subtitle: "Jaśniejsze pole to dzień z większą liczbą podyktowanych słów."
        ) {
            VFActivityGrid(series: activity)
        }
    }

    /// Największe aplikacje osobno, reszta w jednym wycinku — pierścień z
    /// kilkunastoma wąskimi paskami nie niesie już żadnej informacji.
    private static let donutLimit = 5

    private var donutSegments: [VFDonutSegment] {
        let shares = summary.appShares
        guard !shares.isEmpty else { return [] }
        let top = shares.prefix(Self.donutLimit)
        var segments = top.map {
            VFDonutSegment(
                id: $0.bundleID,
                label: AppShareList.displayName(for: $0.bundleID),
                value: $0.words,
                share: $0.share
            )
        }
        let rest = shares.dropFirst(Self.donutLimit)
        if !rest.isEmpty {
            let words = rest.reduce(0) { $0 + $1.words }
            segments.append(VFDonutSegment(
                id: "vf.pozostale",
                label: "Pozostałe (\(rest.count))",
                value: words,
                share: rest.reduce(0) { $0 + $1.share }
            ))
        }
        return segments
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter
    }()

    private static func dayLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func polishDays(_ count: Int) -> String {
        if count == 1 { return "dzień" }
        return "dni"
    }
}

/// Nazwa aplikacji docelowej z systemu (po bundle id), nie surowy identyfikator
/// — legenda wykresu ma mówić „Slack", a nie „com.tinyspeck.slackmacgap".
enum AppShareList {
    static func displayName(for bundleID: String) -> String {
        guard bundleID != StatsLib.unknownAppBundleID else { return "Nieznana aplikacja" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        // Bez zainstalowanej aplikacji zostaje ostatni człon bundle id —
        // czytelniejszy niż cały odwrócony adres domeny.
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
