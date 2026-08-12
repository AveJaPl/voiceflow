import SwiftUI

/// Pulpit — pierwsza zakładka: co konto zrobiło dziś i w sumie, plus trzy
/// ostatnie dyktowania.
///
/// Wszystko liczymy z JEDNEGO zapytania `GET /history?limit=200` — serwer nie
/// ma endpointu ze statystykami, a 200 wpisów to jedno małe pobranie zamiast
/// drugiego API. Konsekwencja jest wprost napisana w UI: sumy dotyczą
/// ostatnich 200 dyktowań, nie całej wieczności.
struct DashboardView: View {
    @ObservedObject var remote: RemoteSession

    @State private var entries: [AccountAPI.HistoryEntry] = []
    @State private var loading = false
    @State private var errorText: String?

    private static let limit = 200

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if let errorText {
                        Text(errorText)
                            .font(VFFont.body(13))
                            .foregroundStyle(VFColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if entries.isEmpty && !loading {
                        Text("Brak dyktowań na koncie. Podyktuj coś na Macu albo z telefonu.")
                            .font(VFFont.body(13))
                            .foregroundStyle(VFColor.faint)
                    } else {
                        statsGrid
                        recentList
                    }
                }
                .padding(24)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Pulpit")
        .task { await load() }
        .onChange(of: remote.isPaired) { _, _ in Task { await load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PODSUMOWANIE").vfEyebrow()
            Text(loading ? "Odświeżam…" : "Ostatnie \(Self.limit) dyktowań Twojego konta.")
                .font(VFFont.body(12.5))
                .foregroundStyle(VFColor.faint)
        }
        .padding(.top, 12)
    }

    private var statsGrid: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let todayEntries = entries.filter { $0.createdAt >= today }
        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
        let todayWords = todayEntries.reduce(0) { $0 + $1.wordCount }
        let speaking = entries.reduce(0.0) { $0 + $1.durationSeconds }

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(label: "SŁOWA DZIŚ", value: "\(todayWords)")
            StatTile(label: "SŁOWA ŁĄCZNIE", value: "\(totalWords)")
            StatTile(label: "DYKTOWANIA", value: "\(entries.count)")
            StatTile(label: "CZAS MÓWIENIA", value: VFDuration.label(speaking))
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OSTATNIE DYKTOWANIA").vfEyebrow()
            VStack(spacing: 0) {
                ForEach(entries.prefix(3)) { entry in
                    HistoryRow(entry: entry)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(VFColor.border).frame(height: 1)
                        }
                }
            }
            .background(VFColor.surface)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
        }
    }

    private func load() async {
        guard let credentials = remote.accountCredentials else {
            entries = []
            errorText = AccountAPI.Failure.unauthorized.message
            return
        }
        loading = true
        defer { loading = false }
        do {
            entries = try await AccountAPI.history(credentials: credentials, limit: Self.limit)
            errorText = nil
        } catch let failure as AccountAPI.Failure {
            errorText = failure.message
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).vfEyebrow()
            Text(value)
                .font(VFFont.display(26, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(VFColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VFColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
    }
}

/// Wiersz historii — wspólny dla Pulpitu (ostatnie trzy) i zakładki Historia.
struct HistoryRow: View {
    let entry: AccountAPI.HistoryEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "pl_PL")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Self.dateFormatter.string(from: entry.createdAt))
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
                Text(VFDuration.label(entry.durationSeconds))
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
                Spacer()
                Text(entry.target ?? entry.source.uppercased())
                    .font(VFFont.mono(10))
                    .tracking(1)
                    .foregroundStyle(VFColor.faint)
                    .lineLimit(1)
            }
            Text(entry.text)
                .font(VFFont.body(14))
                .foregroundStyle(VFColor.text)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
