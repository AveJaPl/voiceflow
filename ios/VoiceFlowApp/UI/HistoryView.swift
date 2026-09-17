import SwiftUI

struct HistoryView: View {
    @ObservedObject var account: AccountSession
    @State private var entries: [DictationEntry] = []
    @State private var query = ""
    @State private var copied: String?

    private var localEntries: [DictationEntry] {
        entries.filter { entry in
            (entry.accountKey == nil || entry.accountKey == account.accountKey)
                && !account.history.contains { $0.source == "phone:\(entry.id.uuidString)" }
        }
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }

    var body: some View {
        List {
            if account.isPaired {
                Section("Historia konta · Mac i iPhone") {
                    if !account.status.isEmpty { Text(account.status).font(.caption).foregroundStyle(VFColor.muted) }
                    if account.history.isEmpty { Text("Brak pobranych wpisów. Przeciągnij w dół, aby odświeżyć.").foregroundStyle(VFColor.muted) }
                    ForEach(account.history.filter { matches($0.text) }) { entry in
                        row(id: "remote:\(entry.id)", text: entry.text, date: entry.createdAt,
                            source: entry.source.hasPrefix("phone") ? "iPhone" : "Mac")
                    }
                }
            } else {
                Text("Zaloguj się w Ustawieniach tym samym kontem co na Macu, aby zobaczyć wspólną historię.")
                    .font(.callout).foregroundStyle(VFColor.muted)
            }
            Section("Na tym telefonie") {
                if localEntries.isEmpty && account.history.isEmpty {
                    Text("Twoje dyktowania pojawią się tutaj.").foregroundStyle(VFColor.muted)
                }
                ForEach(localEntries.filter { matches($0.text) }) { entry in
                    row(id: entry.id.uuidString, text: entry.text, date: entry.date,
                        source: entry.accountKey == nil ? "Lokalnie" : "Kopia lokalna")
                }
            }
        }
        .scrollContentBackground(.hidden).background(VFColor.background)
        .navigationTitle("Historia").searchable(text: $query, prompt: "Szukaj")
        .onAppear { entries = DictationHistoryStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: .init("voiceflow.historyChanged"))) { _ in
            entries = DictationHistoryStore.load()
        }
        .task(id: account.accountKey) { await account.refresh() }
        .refreshable { entries = DictationHistoryStore.load(); await account.refresh() }
    }

    private func row(id: String, text: String, date: Date, source: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(date, style: .date)
                Text(date, style: .time)
                Spacer()
                Text(source)
            }.font(.caption).foregroundStyle(VFColor.muted)
            Text(text).textSelection(.enabled)
            Button(copied == id ? "Skopiowano" : "Kopiuj") {
                UIPasteboard.general.string = text
                copied = id
            }.font(.caption)
        }.padding(.vertical, 8).listRowBackground(VFColor.surfaceSolid)
    }
}
