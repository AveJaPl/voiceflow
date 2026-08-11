import SwiftUI
import AppKit

/// Historia i Statystyki — dwie strony, których Mac dotąd nie miał w tej formie.
/// Układ i teksty przepisane z `app/voiceflow_app/pages/history.py` i `stats.py`.

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

struct StatsPage: View {
    @ObservedObject var model: AppUIModel

    private var totals: StatsLib.Totals { StatsLib.totals(model.notes) }
    private var daily: [(day: Date, words: Int)] { StatsLib.dailySeries(model.notes, days: 31) }
    private var activity: [(day: Date, words: Int)] { StatsLib.dailySeries(model.notes, days: 182) }

    var body: some View {
        VFPageHeader(
            title: "Statystyki",
            subtitle: "Twój rytm dyktowania, liczony wyłącznie z lokalnej historii."
        )

        if model.notes.isEmpty {
            Text("Brak statystyk. Pierwsze dyktowanie uruchomi podsumowania i wykresy.")
                .font(VF.Font.body(13))
                .foregroundStyle(VF.Color.muted)
                .vfCard()
        } else {
            HStack(alignment: .top, spacing: VF.Space.x12) {
                VFStatCard(label: "Łącznie słów", value: StatsLib.compactNumber(totals.words))
                VFStatCard(label: "Dyktowań", value: StatsLib.compactNumber(totals.dictations))
                VFStatCard(label: "Czas mówienia", value: StatsLib.formatDuration(totals.audioSeconds))
                VFStatCard(
                    label: "Średnio słów",
                    value: String(format: "%.0f", totals.averageWords.rounded())
                )
            }

            VFSection(title: "Słowa dziennie", subtitle: "Ostatnie 31 dni.") {
                VFBarChart(values: daily.map { $0.words }, height: 140)
            }

            VFSection(title: "Aktywność · 26 tygodni") {
                VFActivityGrid(series: activity)
            }
        }
    }
}
