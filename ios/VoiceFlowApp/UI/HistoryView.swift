import SwiftUI

struct HistoryView: View {
    @State private var entries: [DictationEntry] = []
    @State private var query = ""
    @State private var copied: UUID?
    var body: some View {
        List {
            if entries.isEmpty {
                Text("Twoje dyktowania pojawią się tutaj. Historia jest zapisywana na telefonie.")
                    .foregroundStyle(VFColor.muted)
            }
            ForEach(entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.date, style: .date).font(.caption).foregroundStyle(VFColor.muted)
                    Text(entry.text).textSelection(.enabled)
                    Button(copied == entry.id ? "Skopiowano" : "Kopiuj") {
                        UIPasteboard.general.string = entry.text
                        copied = entry.id
                    }.font(.caption)
                }.padding(.vertical, 8).listRowBackground(VFColor.surfaceSolid)
            }
        }.scrollContentBackground(.hidden).background(VFColor.background)
            .navigationTitle("Historia").searchable(text: $query, prompt: "Szukaj")
            .onAppear { entries = DictationHistoryStore.load() }
    }
}
