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

            // Konto + wersja w lewym dolnym rogu. E-mail pojawia się po
            // zalogowaniu w Ustawieniach; wersja z Info.plist podbija się
            // sama przy publikacji (`tools/release-mac.sh`).
            if let email = UserDefaults.standard.string(forKey: SettingsKeys.accountEmail), !email.isEmpty {
                Text(email)
                    .font(VF.Font.mono(10))
                    .foregroundStyle(VF.Color.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, VF.Space.x12)
            }
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .font(VF.Font.mono(10))
                .foregroundStyle(VF.Color.faint)
                .padding(.horizontal, VF.Space.x12)
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
            // `embedded` — nagłówek, przewijanie i szerokość daje ta strona,
            // więc widok ustawień nie może narzucać własnego rozmiaru okna.
            SettingsView(model: settingsModel, remoteMic: remoteMic, embedded: true)
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

    /// Średnia z dni, w których cokolwiek podyktowano — sama liczba słów z
    /// dzisiaj nic nie mówi, dopóki nie ma jej z czym porównać.
    private var averageActiveDay: Double {
        StatsLib.averageWordsPerActiveDay(model.notes)
    }

    private var todayComparison: String {
        guard averageActiveDay > 0 else { return "przytrzymaj skrót i mów" }
        let average = Int(averageActiveDay.rounded())
        guard todayWords > 0 else { return "średnia dnia: \(StatsLib.compactNumber(average)) słów" }
        let ratio = Int((Double(todayWords) * 100 / averageActiveDay).rounded()) - 100
        // Minus typograficzny, tak samo jak w `StatsLib.compactNumber`.
        let direction = ratio >= 0 ? "+\(ratio)%" : "−\(abs(ratio))%"
        return "\(direction) względem średniej \(StatsLib.compactNumber(average)) słów"
    }

    var body: some View {
        VFPageHeader(
            title: "Przegląd",
            subtitle: "Stan dyktowania i twój rytm pracy, liczony wyłącznie z lokalnej historii."
        )

        HStack(alignment: .top, spacing: VF.Space.x16) {
            HStack(alignment: .top, spacing: VF.Space.x12) {
                Circle()
                    .fill(model.isRecording ? VF.Color.recording : VF.Color.faint)
                    .frame(width: 10, height: 10)
                    // Kropka trafia w linię pisma tytułu, a nie w środek całej
                    // kolumny tekstu — inaczej wisi za nisko przy dwóch liniach.
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.stateTitle)
                        .font(VF.Font.display(22))
                        .foregroundStyle(VF.Color.text)
                    Text(model.stateDetail.isEmpty ? "Przytrzymaj skrót i mów" : model.stateDetail)
                        .font(VF.Font.body(12))
                        .foregroundStyle(VF.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text(todayComparison)
                    .font(VF.Font.body(11).monospacedDigit())
                    .foregroundStyle(VF.Color.muted)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
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

/// Układ jeden do jednego z aplikacją linuksową (`pages/vocabulary.py`):
/// karta dodawania na górze, licznik terminów jako etykieta sekcji, a pod nim
/// siatka pięciu kafelków w wierszu. Terminu nie usuwa się z listy, tylko
/// krzyżykiem na samym kafelku — pojawia się dopiero pod kursorem, żeby siatka
/// w spoczynku była czystym zbiorem słów.
struct VocabularyPage: View {
    @State private var terms: [String] = []
    @State private var draft: String = ""
    @State private var hovered: String?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: VF.Space.x8),
        count: 5
    )

    var body: some View {
        VFPageHeader(
            title: "Słownik",
            subtitle: "Dodaj nazwy własne i terminy, które Whisper ma rozpoznawać dokładniej."
        )

        VStack(alignment: .leading, spacing: VF.Space.x8) {
            HStack(spacing: VF.Space.x12) {
                TextField("Dodaj termin…", text: $draft)
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
            .vfCard()

            Text("Terminy trafiają wprost do promptu dekodera whisper.cpp — działają od razu, "
                + "bez restartu. Trzymaj listę krótką: zbyt długa pogarsza rozpoznawanie.")
                .font(VF.Font.body(12))
                .foregroundStyle(VF.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: VF.Space.x16) {
            Text(counter).vfSectionLabel()

            if terms.isEmpty {
                VStack(spacing: VF.Space.x8) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 24))
                        .foregroundStyle(VF.Color.faint)
                    Text("Słownik jest pusty. Dodaj pierwszy termin w polu powyżej.")
                        .font(VF.Font.body(13))
                        .foregroundStyle(VF.Color.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                LazyVGrid(columns: Self.columns, spacing: VF.Space.x8) {
                    ForEach(terms, id: \.self) { term in
                        tile(term)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    private var counter: String {
        terms.count == 1 ? "1 TERMIN" : "\(terms.count) TERMINÓW"
    }

    private func tile(_ term: String) -> some View {
        Text(term)
            .font(VF.Font.body(13).weight(.medium))
            .foregroundStyle(VF.Color.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, VF.Space.x16)
            .padding(.vertical, VF.Space.x12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                    .fill(VF.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VF.Radius.control, style: .continuous)
                    .strokeBorder(VF.Color.border, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    remove(term)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(VF.Color.text)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(VF.Color.background.opacity(0.82)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(VF.Space.x4)
                .opacity(hovered == term ? 1 : 0)
                .help("Usuń termin \(term)")
            }
            .onHover { inside in
                hovered = inside ? term : (hovered == term ? nil : hovered)
            }
            .animation(VF.Motion.quick, value: hovered)
    }

    private func load() {
        terms = UserDefaults.standard.stringArray(forKey: SettingsKeys.customVocabulary) ?? []
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
        else { return }
        terms.append(value)
        draft = ""
        persist()
    }

    private func remove(_ term: String) {
        terms.removeAll { $0 == term }
        hovered = nil
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(terms, forKey: SettingsKeys.customVocabulary)
    }
}
