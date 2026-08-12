import SwiftUI

/// Historia dyktowań z konta (`GET /history`), a nie z App Group — wpisy
/// powstają na Macu i na telefonie, więc jedyne miejsce, w którym widać
/// całość, jest po stronie relaya.
///
/// Paginacja: serwer nie zna offsetu, tylko `before=<createdAt>` — dociągamy
/// starsze wpisy, gdy user dojedzie do końca listy. Dlatego przy dopisywaniu
/// odsiewamy duplikaty po `id` (wpisy z identycznym `createdAt` mogą przyjść
/// w obu stronach).
struct HistoryView: View {
    @ObservedObject var remote: RemoteSession

    @State private var entries: [AccountAPI.HistoryEntry] = []
    @State private var query = ""
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var errorText: String?

    private static let pageSize = 50

    private var visible: [AccountAPI.HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.text.lowercased().contains(needle) }
    }

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            if let errorText, entries.isEmpty {
                message(errorText)
            } else if entries.isEmpty && !loading {
                message("Brak dyktowań. Podyktowany tekst pojawi się tutaj.")
            } else {
                list
            }
        }
        .navigationTitle("Historia")
        .searchable(text: $query, prompt: "Szukaj w historii")
        .task { await reload() }
        .onChange(of: remote.isPaired) { _, _ in Task { await reload() } }
    }

    private var list: some View {
        List {
            ForEach(visible) { entry in
                HistoryRow(entry: entry)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(VFColor.background)
                    .listRowSeparatorTint(VFColor.border)
                    .swipeActions(edge: .trailing) {
                        Button("Usuń", role: .destructive) {
                            Task { await delete(entry) }
                        }
                    }
                    .onAppear {
                        // Doładowanie startuje na ostatnim wpisie — przy
                        // aktywnym wyszukiwaniu też, bo filtr jest lokalny
                        // i użytkownik może szukać w jeszcze niepobranych.
                        if entry.id == entries.last?.id { Task { await loadMore() } }
                    }
            }
            if loading {
                Text("Wczytuję…")
                    .font(VFFont.mono(11))
                    .foregroundStyle(VFColor.faint)
                    .listRowBackground(VFColor.background)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await reload() }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(VFFont.body(13))
            .foregroundStyle(VFColor.muted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }

    // MARK: - Dane

    private func reload() async {
        guard let credentials = remote.accountCredentials else {
            entries = []
            errorText = AccountAPI.Failure.unauthorized.message
            return
        }
        loading = true
        defer { loading = false }
        do {
            entries = try await AccountAPI.history(credentials: credentials, limit: Self.pageSize)
            reachedEnd = entries.count < Self.pageSize
            errorText = nil
        } catch let failure as AccountAPI.Failure {
            errorText = failure.message
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd,
              let credentials = remote.accountCredentials,
              let oldest = entries.last?.createdAt
        else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await AccountAPI.history(
                credentials: credentials,
                limit: Self.pageSize,
                before: oldest
            )
            let known = Set(entries.map(\.id))
            entries.append(contentsOf: page.filter { !known.contains($0.id) })
            reachedEnd = page.count < Self.pageSize
        } catch let failure as AccountAPI.Failure {
            errorText = failure.message
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ entry: AccountAPI.HistoryEntry) async {
        guard let credentials = remote.accountCredentials else { return }
        // Znika od razu; gdyby serwer odmówił, wraca przy najbliższym
        // odświeżeniu i user widzi powód.
        entries.removeAll { $0.id == entry.id }
        do {
            try await AccountAPI.deleteHistoryEntry(id: entry.id, credentials: credentials)
        } catch let failure as AccountAPI.Failure {
            errorText = failure.message
        } catch {
            errorText = error.localizedDescription
        }
    }
}
