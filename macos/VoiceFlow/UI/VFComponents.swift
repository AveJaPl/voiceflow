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

    /// Kafelki stoją obok siebie, więc muszą być tej samej wysokości i mieć
    /// liczbę w tej samej linii — stąd stała wysokość podpisu (dwie linie
    /// zarezerwowane, nawet gdy tekst zajmuje jedną) i skalowanie samej liczby
    /// zamiast łamania jej na dwie linie.
    var body: some View {
        VStack(alignment: .leading, spacing: VF.Space.x8) {
            Text(label)
                .vfSectionLabel()
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: VF.Space.x4) {
                Text(value)
                    .font(VF.Font.display(28))
                    .foregroundStyle(VF.Color.text)
                if let suffix {
                    Text(suffix)
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.faint)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(trend ?? " ")
                .font(VF.Font.body(11))
                .foregroundStyle(VF.Color.muted)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .vfCard()
    }
}

// MARK: - Wykres kołowy (donut)

/// Jeden wycinek pierścienia. `share` to gotowy procent z `StatsLib`, żeby
/// legenda i reszta panelu pokazywały tę samą liczbę.
struct VFDonutSegment: Identifiable {
    let id: String
    let label: String
    let value: Int
    let share: Int
}

/// Pierścień z legendą obok. Monochromatycznie — kolejne wycinki różnią się
/// wyłącznie jasnością, bo jedynym kolorem w interfejsie jest czerwień
/// nagrywania. Wycinki oddziela cienka przerwa w tle karty, więc granice widać
/// bez obrysu.
struct VFDonutChart: View {
    let segments: [VFDonutSegment]
    /// Liczba w środku pierścienia (np. wszystkie słowa) i jej podpis.
    let centerValue: String
    let centerCaption: String
    var diameter: CGFloat = 168
    var thickness: CGFloat = 24

    private var total: Double { max(Double(segments.reduce(0) { $0 + $1.value }), 1) }

    /// Ułamek pełnego obrotu, na którym kończy się wycinek o podanym indeksie.
    private func bounds(_ index: Int) -> (start: CGFloat, end: CGFloat) {
        let before = segments.prefix(index).reduce(0) { $0 + $1.value }
        let start = CGFloat(Double(before) / total)
        let end = start + CGFloat(Double(segments[index].value) / total)
        return (start, end)
    }

    /// Jasność maleje wraz z pozycją — pierwszy, największy udział jest
    /// najjaśniejszy, ostatni ledwie odcina się od tła.
    static func shade(_ index: Int, of count: Int) -> Double {
        guard count > 1 else { return 0.92 }
        let step = (0.92 - 0.26) / Double(count - 1)
        return 0.92 - step * Double(index)
    }

    var body: some View {
        HStack(alignment: .center, spacing: VF.Space.x24) {
            ring
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .strokeBorder(VF.Color.hairline, lineWidth: thickness)
            ForEach(segments.indices, id: \.self) { index in
                let span = bounds(index)
                Circle()
                    .trim(from: span.start, to: max(span.start, span.end - 0.004))
                    .stroke(
                        VF.Color.text.opacity(Self.shade(index, of: segments.count)),
                        style: StrokeStyle(lineWidth: thickness, lineCap: .butt)
                    )
                    .padding(thickness / 2)
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(centerValue)
                    .font(VF.Font.display(22))
                    .foregroundStyle(VF.Color.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(centerCaption)
                    .font(VF.Font.body(11))
                    .foregroundStyle(VF.Color.faint)
                    .lineLimit(1)
            }
            .frame(width: diameter - thickness * 2 - VF.Space.x8)
        }
        .frame(width: diameter, height: diameter)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: VF.Space.x8) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                HStack(spacing: VF.Space.x12) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(VF.Color.text.opacity(Self.shade(index, of: segments.count)))
                        .frame(width: 10, height: 10)
                    Text(segment.label)
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(segment.share)%")
                        .font(VF.Font.body(12).monospacedDigit())
                        .foregroundStyle(VF.Color.muted)
                        .frame(width: 44, alignment: .trailing)
                    Text("\(StatsLib.compactNumber(segment.value)) słów")
                        .font(VF.Font.body(11).monospacedDigit())
                        .foregroundStyle(VF.Color.faint)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        // Legenda nie rozciąga się na całą kartę: procent i liczba słów mają
        // stać tuż obok nazwy, a nie po drugiej stronie okna.
        .frame(maxWidth: 460, alignment: .leading)
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

// MARK: - Przełącznik zakresu

/// Segmentowany wybór w palecie VF. `Picker(.segmented)` rysuje zaznaczenie
/// systemowym akcentem (u Wojtka niebieskim) — jedyny kolorowy element w całym
/// oknie, w interfejsie, w którym kolor ma znaczyć „trwa nagrywanie".
struct VFSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: VF.Space.x4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(VF.Font.body(12))
                        .padding(.horizontal, VF.Space.x12)
                        .padding(.vertical, VF.Space.x8)
                        .foregroundStyle(isSelected ? VF.Color.background : VF.Color.muted)
                        .background(
                            RoundedRectangle(cornerRadius: VF.Radius.control - 2, style: .continuous)
                                .fill(isSelected ? VF.Color.text : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(VF.Space.x4)
        .background(
            RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                .fill(VF.Color.surfaceRaised)
        )
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
