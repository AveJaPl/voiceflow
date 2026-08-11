import SwiftUI

/// Historia dyktowań z App Group — wspólna dla ekranu dyktowania w apce
/// (plan B) i przyszłego zapisu z klawiatury.
struct HistoryView: View {
    @State private var entries: [DictationEntry] = DictationHistoryStore.load()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "pl_PL")
        return f
    }()

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Text("BRAK HISTORII")
                        .font(VFFont.display(16, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(VFColor.muted)
                    Text("Podyktowany tekst pojawi się tutaj.")
                        .font(VFFont.body(13))
                        .foregroundStyle(VFColor.faint)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(Self.dateFormatter.string(from: entry.date))
                                        .font(VFFont.mono(10))
                                        .foregroundStyle(VFColor.faint)
                                    Spacer()
                                    Text(entry.source == .keyboard ? "KLAWIATURA" : "APKA")
                                        .font(VFFont.mono(10))
                                        .tracking(1)
                                        .foregroundStyle(VFColor.faint)
                                }
                                Text(entry.text)
                                    .font(VFFont.body(14))
                                    .foregroundStyle(VFColor.text)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(VFColor.border).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Historia")
        .onAppear { entries = DictationHistoryStore.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !entries.isEmpty {
                    Button("Wyczyść") {
                        DictationHistoryStore.clear()
                        entries = []
                    }
                    .font(VFFont.body(13))
                    .foregroundStyle(VFColor.muted)
                }
            }
        }
    }
}
