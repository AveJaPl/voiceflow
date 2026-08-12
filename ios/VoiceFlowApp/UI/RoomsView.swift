import SwiftUI

/// Zakładka „Pokoje” — ta sama tablica co na `rooms.pbdevs.com` i na stronie
/// „Pokój” w apce na Macu. Liczby liczy wspólny `RoomBoard` (shared/board),
/// więc telefon nie ma prawa pokazać innego procentu niż Mac przy tej samej
/// sesji.
///
/// Telefon tylko OGLĄDA: zakładanie pokoju, dołączanie i otwieranie sesji
/// zostaje na Macu, bo tam się dyktuje. Tutaj wystarczy kod pokoju — bez
/// tokenu, bo `GET /api/rooms/:kod/ranking` jest publiczny.
@MainActor
final class RoomsModel: ObservableObject {
    @Published var snapshot: RoomSnapshot = .empty
    @Published var elapsed = "—"
    @Published var status: String?
    @Published private(set) var code: String

    /// Serwer pokoi jest jeden i nie ma go po co konfigurować na telefonie —
    /// Mac też trzyma go jako domyślny.
    static let server = "https://rooms.pbdevs.com"
    static let codeKey = "voiceflow.roomCode"

    private let defaults: UserDefaults
    private var timer: Timer?
    private var secondsSinceRefresh = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.code = defaults.string(forKey: Self.codeKey) ?? ""
    }

    var hasRoom: Bool { !code.isEmpty }

    // MARK: - Cykl życia

    func onAppear() {
        // Zegar sesji musi iść co sekundę niezależnie od odpytywania serwera,
        // inaczej stoi w miejscu między odświeżeniami tablicy.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refresh() }
    }

    func onDisappear() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let startedAt = snapshot.sessionStartedAt {
            elapsed = RoomBoard.sessionElapsed(startedAt: startedAt)
        }
        // Tablica co 5 s — częściej nie ma sensu, bo i tak zmienia się dopiero
        // po czyjejś wypowiedzi.
        secondsSinceRefresh += 1
        if secondsSinceRefresh >= 5 {
            secondsSinceRefresh = 0
            Task { await refresh() }
        }
    }

    // MARK: - Dane

    func setCode(_ raw: String) {
        code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        defaults.set(code, forKey: Self.codeKey)
        snapshot = .empty
        elapsed = "—"
        status = nil
        Task { await refresh() }
    }

    func forgetCode() {
        setCode("")
    }

    func refresh() async {
        guard hasRoom else {
            snapshot = .empty
            elapsed = "—"
            return
        }
        secondsSinceRefresh = 0
        do {
            snapshot = try await RoomBoardClient.fetchRanking(server: Self.server, code: code)
            if let startedAt = snapshot.sessionStartedAt {
                elapsed = RoomBoard.sessionElapsed(startedAt: startedAt)
            } else {
                elapsed = "—"
            }
            status = nil
        } catch {
            // Stara tablica pokazana jako aktualna kłamie — mówimy wprost,
            // że nie wiemy, zamiast rysować nieświeże liczby bez ostrzeżenia.
            status = "Nie udało się odczytać tablicy pokoju."
        }
    }
}

struct RoomsView: View {
    @StateObject private var model = RoomsModel()
    @State private var draftCode = ""

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if model.hasRoom { board } else { codeEntry }

                    if let status = model.status {
                        Text(status)
                            .font(VFFont.body(12.5))
                            .foregroundStyle(VFColor.muted)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Pokoje")
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    // MARK: - Bez pokoju

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("KOD POKOJU").vfEyebrow()
            Text("Sześcioznakowy kod z Maca — telefon pokazuje tablicę, dyktuje się dalej tam.")
                .font(VFFont.body(12.5))
                .foregroundStyle(VFColor.faint)
            TextField("np. AB12CD", text: $draftCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(VFFont.mono(16))
                .foregroundStyle(VFColor.text)
                .padding(14)
                .background(VFColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
                .onSubmit { model.setCode(draftCode) }
            Button("Pokaż tablicę") { model.setCode(draftCode) }
                .buttonStyle(VFOutlineButtonStyle(solid: true))
                .disabled(draftCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 12)
    }

    // MARK: - W pokoju

    private var board: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.snapshot.sessionName ?? "Sesja bez nazwy")
                    .font(VFFont.display(22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(VFColor.text)
                Text("kod \(model.code) · trwa \(model.elapsed)")
                    .font(VFFont.mono(11))
                    .foregroundStyle(VFColor.muted)
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 12) {
                Text("TABLICA").vfEyebrow()
                if model.snapshot.rows.isEmpty {
                    Text("Jeszcze nikt nic nie podyktował w tej sesji.")
                        .font(VFFont.body(13))
                        .foregroundStyle(VFColor.faint)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.snapshot.rows) { row in
                            BoardRowView(row: row)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(VFColor.border).frame(height: 1)
                                }
                        }
                    }
                    .background(VFColor.surface)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
                }
            }

            Button("Zmień kod pokoju") {
                draftCode = ""
                model.forgetCode()
            }
            .buttonStyle(VFOutlineButtonStyle())
        }
    }
}

/// Wiersz tablicy — te same kolumny co na tablicy webowej i na Macu: pozycja,
/// imię, dyktowania, średnia słów, czas mówienia, słowa, udział i dystans do
/// lidera.
private struct BoardRowView: View {
    let row: BoardRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(row.position)")
                .font(VFFont.mono(13))
                .foregroundStyle(VFColor.faint)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(VFFont.body(15, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                Text("\(row.dictations) dyktowań · śr. \(row.averageWords) sł. · \(RoomBoard.formatDuration(seconds: Double(row.seconds)))")
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(row.words) sł.")
                    .font(VFFont.body(15, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                Text(row.behind == 0 ? "\(row.share)% · lider" : "\(row.share)% · −\(row.behind)")
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
