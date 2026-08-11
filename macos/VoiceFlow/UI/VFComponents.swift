import SwiftUI

/// Klocki interfejsu odwzorowujące aplikację linuksową: nagłówek strony,
/// karta sekcji, kafelek liczby, wykres słupkowy i kalendarz aktywności.
///
/// Wszystkie rysują się z tokenów w `Theme.swift`, więc zmiana palety w jednym
/// miejscu przechodzi przez cały interfejs — tak samo jak arkusz stylów robi to
/// po stronie Linuksa.

// MARK: - Nagłówek strony

struct VFPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: VF.Space.x4) {
            Text(title)
                .font(VF.Font.display(28))
                .foregroundStyle(VF.Color.text)
            Text(subtitle)
                .font(VF.Font.body(13))
                .foregroundStyle(VF.Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sekcja i karta

struct VFSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VF.Space.x12) {
            VStack(alignment: .leading, spacing: VF.Space.x4) {
                Text(title).vfSectionLabel()
                if let subtitle {
                    Text(subtitle)
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: VF.Space.x12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .vfCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wiersz ustawienia: etykieta z opisem po lewej, kontrolka po prawej —
/// odpowiednik `Adw.ActionRow` z aplikacji linuksowej.
struct VFRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: VF.Space.x16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VF.Font.body(13))
                    .foregroundStyle(VF.Color.text)
                if let subtitle {
                    Text(subtitle)
                        .font(VF.Font.body(11))
                        .foregroundStyle(VF.Color.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: VF.Space.x12)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Kafelek liczby

struct VFStatCard: View {
    let label: String
    let value: String
    var suffix: String?
    var trend: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VF.Space.x8) {
            Text(label).vfSectionLabel()
            HStack(alignment: .firstTextBaseline, spacing: VF.Space.x4) {
                Text(value)
                    .font(VF.Font.display(30))
                    .foregroundStyle(VF.Color.text)
                if let suffix {
                    Text(suffix)
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.faint)
                }
            }
            Text(trend ?? " ")
                .font(VF.Font.body(11))
                .foregroundStyle(VF.Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfCard()
    }
}

// MARK: - Wykres słupkowy

/// Słupki o zaokrąglonej górze i prostej podstawie — ten sam kształt, który
/// aplikacja linuksowa rysuje w Cairo. Pusty szereg to celowo pusty wykres z
/// komunikatem, a nie płaska linia udająca dane.
struct VFBarChart: View {
    let values: [Int]
    var height: CGFloat = 120
    var emptyMessage: String = "Brak danych"

    private var maximum: Int { max(values.max() ?? 0, 1) }

    var body: some View {
        if values.isEmpty || values.allSatisfy({ $0 == 0 }) {
            Text(emptyMessage)
                .font(VF.Font.body(12))
                .foregroundStyle(VF.Color.faint)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        } else {
            GeometryReader { geometry in
                let count = max(values.count, 1)
                let spacing: CGFloat = count > 40 ? 1 : 3
                let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(values.indices, id: \.self) { index in
                        let ratio = CGFloat(values[index]) / CGFloat(maximum)
                        UnevenRoundedRectangle(
                            topLeadingRadius: 2, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 2
                        )
                        .fill(values[index] > 0 ? VF.Color.text.opacity(0.82) : VF.Color.hairline)
                        .frame(width: barWidth, height: max(2, ratio * geometry.size.height))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            }
            .frame(height: height)
        }
    }
}

// MARK: - Kalendarz aktywności

/// Siatka tygodni (kolumna = tydzień, wiersz = dzień), pięć stopni jasności —
/// odpowiednik „Aktywność · 26 tygodni" z Linuksa. Monochromatycznie, bo
/// jedynym kolorem w interfejsie jest czerwień nagrywania.
struct VFActivityGrid: View {
    /// Od najstarszego do najnowszego, gęsto (dni bez dyktowania jako zero).
    let series: [(day: Date, words: Int)]
    var cell: CGFloat = 11
    var spacing: CGFloat = 3

    private var thresholds: (q1: Int, q2: Int, q3: Int) {
        StatsLib.quantileThresholds(series.map { $0.words })
    }

    /// Kolumny po siedem dni. Ostatnia kolumna bywa niepełna — to bieżący,
    /// jeszcze trwający tydzień.
    private var weeks: [[(day: Date, words: Int)]] {
        stride(from: 0, to: series.count, by: 7).map { start in
            Array(series[start..<min(start + 7, series.count)])
        }
    }

    private func shade(_ level: Int) -> Color {
        switch level {
        case 0: return VF.Color.hairline
        case 1: return VF.Color.text.opacity(0.22)
        case 2: return VF.Color.text.opacity(0.42)
        case 3: return VF.Color.text.opacity(0.64)
        default: return VF.Color.text.opacity(0.9)
        }
    }

    var body: some View {
        if series.isEmpty {
            Text("Brak danych")
                .font(VF.Font.body(12))
                .foregroundStyle(VF.Color.faint)
        } else {
            let limits = thresholds
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(weeks.indices, id: \.self) { weekIndex in
                        let week = weeks[weekIndex]
                        VStack(spacing: spacing) {
                            ForEach(week.indices, id: \.self) { dayIndex in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(shade(StatsLib.activityLevel(week[dayIndex].words, thresholds: limits)))
                                    .frame(width: cell, height: cell)
                                    .help("\(week[dayIndex].words) słów")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Przycisk w stylu linuksowym

struct VFButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VF.Font.body(13))
            .foregroundStyle(prominent ? VF.Color.background : VF.Color.text)
            .padding(.horizontal, VF.Space.x16)
            .padding(.vertical, VF.Space.x8)
            .background(
                RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                    .fill(prominent ? VF.Color.text : VF.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : VF.Color.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(VF.Motion.quick, value: configuration.isPressed)
    }
}
