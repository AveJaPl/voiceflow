import SwiftUI
import AppKit

/// Główne okno aplikacji, odwzorowanie okna z Linuksa: boczne menu i pięć
/// stron — Przegląd, Historia, Pokój, Słownik, Ustawienia.
///
/// Do tej pory Mac był wyłącznie aplikacją paska menu z jednym oknem ustawień
/// i osobnym oknem notatek; statystyk nie było wcale. Nazwy stron, ich podtytuły
/// i układ (nagłówek → sekcje w kartach) są przepisane z
/// `app/voiceflow_app/`, bo to aplikacja linuksowa jest wzorcem dla całości.
///
/// Statystyki nie mają własnej pozycji w menu: stan dyktowania i liczby opisują
/// to samo, więc mieszkają razem w Przeglądzie jako jeden panel.

enum VFPage: String, CaseIterable, Identifiable {
    case dashboard, history, room, vocabulary, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Przegląd"
        case .history: "Historia"
        case .room: "Pokój"
        case .vocabulary: "Słownik"
        case .settings: "Ustawienia"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "mic"
        case .history: "clock.arrow.circlepath"
        case .room: "person.2"
        case .vocabulary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

/// Stan, który okno pokazuje. Aktualizowany przez `VoiceFlowApp` — okno samo
/// niczego nie odpytuje, żeby nie było drugiego źródła prawdy o dyktowaniu.
@MainActor
final class AppUIModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var stateTitle: String = "Gotowy"
    @Published var stateDetail: String = ""
    @Published var isRecording: Bool = false

    private let store: NotesStore

    init(store: NotesStore) {
        self.store = store
        reload()
    }

    func reload() {
        store.load()
        notes = store.notes
    }

    func delete(_ id: UUID) {
        store.delete(id: id)
        reload()
    }

    /// Dyktowanie właśnie się skończyło — historia urosła o wpis.
    func noteAdded() {
        reload()
    }
}

struct MainView: View {
    @ObservedObject var model: AppUIModel
    @ObservedObject var settingsModel: SettingsModel
    let remoteMic: RemoteMicClient

    @State private var page: VFPage = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(VF.Color.border)
            ScrollView {
                VStack(alignment: .leading, spacing: VF.Space.x24) {
                    content
                }
                .padding(VF.Space.x32)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(VF.Color.background)
        }
        .background(VF.Color.background)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { model.reload() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: VF.Space.x4) {
            HStack(spacing: VF.Space.x8) {
                Image(systemName: "waveform")
                    .foregroundStyle(VF.Color.text)
                Text("voiceflow")
                    .font(VF.Font.display(16))
                    .foregroundStyle(VF.Color.text)
            }
            .padding(.horizontal, VF.Space.x12)
            .padding(.bottom, VF.Space.x20)

            ForEach(VFPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    HStack(spacing: VF.Space.x12) {
                        Image(systemName: item.symbol)
                            .frame(width: 16)
                        Text(item.title)
                            .font(VF.Font.body(13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VF.Space.x12)
                    .padding(.vertical, VF.Space.x8)
                    .foregroundStyle(page == item ? VF.Color.text : VF.Color.muted)
                    .background(
                        RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                            .fill(page == item ? VF.Color.surfaceRaised : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: VF.Space.x8) {
                Circle()
                    .fill(model.isRecording ? VF.Color.recording : VF.Color.faint)
                    .frame(width: 7, height: 7)
                Text(model.stateTitle)
                    .font(VF.Font.body(11))
                    .foregroundStyle(VF.Color.muted)
            }
            .padding(.horizontal, VF.Space.x12)
            .padding(.bottom, VF.Space.x8)
        }
        .padding(.vertical, VF.Space.x20)
        .frame(width: 248, alignment: .topLeading)
        .background(VF.Color.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .dashboard:
            DashboardPage(model: model)
        case .history:
            HistoryPage(model: model)
        case .room:
            VFPageHeader(
                title: "Pokój",
                subtitle: "Wspólna sesja dyktowania: kto teraz mówi, tablica i ranking."
            )
            RoomPage()
        case .vocabulary:
            VocabularyPage()
        case .settings:
            VFPageHeader(
                title: "Ustawienia",
                subtitle: "Dopasuj model i zachowanie lokalnego dyktowania."
            )
            SettingsView(model: settingsModel, remoteMic: remoteMic)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Przegląd

/// Jedna strona zamiast dwóch: na górze stan dyktowania i ostatni wynik, pod
/// spodem pełny panel statystyk (`StatsInsights`). Liczby, które Przegląd
/// pokazywał wcześniej sam — łącznie słów, seria, wykres tygodnia — zniknęły
/// stąd, bo panel statystyk podaje je dokładniej i w szerszym zakresie.
struct DashboardPage: View {
    @ObservedObject var model: AppUIModel

    private var todayWords: Int {
        StatsLib.dailySeries(model.notes, days: 1).first?.words ?? 0
    }

    var body: some View {
        VFPageHeader(
            title: "Przegląd",
            subtitle: "Stan dyktowania i twój rytm pracy, liczony wyłącznie z lokalnej historii."
        )

        HStack(alignment: .center, spacing: VF.Space.x16) {
            HStack(spacing: VF.Space.x12) {
                Circle()
                    .fill(model.isRecording ? VF.Color.recording : VF.Color.faint)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.stateTitle)
                        .font(VF.Font.display(22))
                        .foregroundStyle(VF.Color.text)
                    Text(model.stateDetail.isEmpty ? "Przytrzymaj skrót i mów" : model.stateDetail)
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.muted)
                }
            }
            Spacer(minLength: VF.Space.x16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Dzisiaj").vfSectionLabel()
                HStack(alignment: .firstTextBaseline, spacing: VF.Space.x4) {
                    Text(StatsLib.compactNumber(todayWords))
                        .font(VF.Font.display(22))
                        .foregroundStyle(VF.Color.text)
                    Text("słów")
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.faint)
                }
            }
        }
        .vfCard(padding: VF.Space.x20)

        VFSection(title: "Ostatnie dyktowanie") {
            if let latest = model.notes.first {
                VStack(alignment: .leading, spacing: VF.Space.x8) {
                    Text(latest.finalText)
                        .font(VF.Font.body(13))
                        .foregroundStyle(VF.Color.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: VF.Space.x8) {
                        Text(latest.createdAt, style: .time)
                        Text("·")
                        Text(StatsLib.formatDuration(latest.duration))
                        if !latest.injected {
                            Text("· nie trafiło do aplikacji")
                                .foregroundStyle(VF.Color.recording)
                        }
                    }
                    .font(VF.Font.body(11))
                    .foregroundStyle(VF.Color.faint)
                    Button("Kopiuj") { copy(latest.finalText) }
                        .buttonStyle(VFButtonStyle())
                }
            } else {
                Text("Podyktowany tekst pojawi się tutaj.")
                    .font(VF.Font.body(12))
                    .foregroundStyle(VF.Color.faint)
            }
        }

        StatsInsights(model: model)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Słownik

struct VocabularyPage: View {
    @State private var terms: [String] = []
    @State private var draft: String = ""

    var body: some View {
        VFPageHeader(
            title: "Słownik",
            subtitle: "Dodaj nazwy własne i terminy, które Whisper ma rozpoznawać dokładniej."
        )

        VFSection(
            title: "Twoje terminy",
            subtitle: "Trafiają wprost do promptu dekodera whisper.cpp — działają od razu, "
                + "bez restartu. Trzymaj listę krótką: zbyt długa pogarsza rozpoznawanie."
        ) {
            HStack(spacing: VF.Space.x8) {
                TextField("np. Supabase", text: $draft)
                    .textFieldStyle(.plain)
                    .font(VF.Font.body(13))
                    .foregroundStyle(VF.Color.text)
                    .padding(.horizontal, VF.Space.x12)
                    .padding(.vertical, VF.Space.x8)
                    .background(
                        RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                            .fill(VF.Color.surfaceRaised)
                    )
                    .onSubmit(add)
                Button("Dodaj", action: add)
                    .buttonStyle(VFButtonStyle(prominent: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if terms.isEmpty {
                Text("Lista jest pusta.")
                    .font(VF.Font.body(12))
                    .foregroundStyle(VF.Color.faint)
            } else {
                ForEach(terms, id: \.self) { term in
                    HStack {
                        Text(term)
                            .font(VF.Font.body(13))
                            .foregroundStyle(VF.Color.text)
                        Spacer()
                        Button {
                            terms.removeAll { $0 == term }
                            persist()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(VF.Color.faint)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        terms = UserDefaults.standard.stringArray(forKey: SettingsKeys.customVocabulary) ?? []
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !terms.contains(value) else { return }
        terms.append(value)
        draft = ""
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(terms, forKey: SettingsKeys.customVocabulary)
    }
}
