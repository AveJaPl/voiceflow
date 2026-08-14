import SwiftUI

/// Zakładka „Mac": podgląd pulpitu, wybór okna i dyktowanie do niego.
///
/// Widok NIE trzyma żadnego stanu poza trybem zatrzasku — wszystko, co ważne,
/// mieszka w `RemoteSession`. Dzięki temu logika, która nie może się pomylić
/// (co, kiedy i do którego okna leci), jest w całości pokryta testami, a tutaj
/// zostaje samo rysowanie.
struct RemoteView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.scenePhase) private var scenePhase

    /// Tryb „naciśnij / naciśnij" włączany dwuklikiem — dla długich promptów,
    /// przy których trzymanie palca przez pół minuty jest męczące.
    @State private var latchedTarget: String?
    /// Jednolinijkowe potwierdzenie ostatniej akcji, znika samo po 2 s.
    @State private var toast: String?
    @State private var toastToken = 0

    private func flash(_ message: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Nowszy komunikat już wygrał — nie kasuj go starym timerem.
            guard token == toastToken else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !session.isPaired {
                    signInCard
                } else if terminals.isEmpty {
                    emptyState
                } else {
                    // Tylko terminale — po to jest ta zakładka. Mapa pulpitu
                    // i pozostałe okna wyleciały: rysowanie mapy z gestami
                    // przy każdej ramce `windows` zauważalnie mulило apkę,
                    // a tap w kartę PRZESTAWIAŁ okna na Macu, zanim jeszcze
                    // cokolwiek podyktowano.
                    screenPreview

                    windowList

                    if let terminal = session.selectedWindow, terminal.isTerminal {
                        TerminalPreview(title: terminal.displayTitle, lines: session.terminalLines)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 160)   // miejsce na pasek mówienia
        }
        .background(VFColor.background)
        .safeAreaInset(edge: .bottom) { speakBar }
        .navigationTitle("Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: session.windows) { _, windows in
            // Pierwszy terminal zaznacza się sam — przycisk „Mów" ma działać
            // od razu, bez obowiązkowego tapnięcia w listę.
            if session.selectedWindowID == nil {
                session.select(windowID: windows.first(where: \.isTerminal)?.id)
            }
        }
        .refreshable {
            session.requestScreenshot()
        }
        .onAppear {
            session.connect()
            session.setViewportActive(true)
        }
        .onDisappear {
            // Poza zakładką Mac nie ma po co niczego wysyłać — cała oszczędność
            // baterii obu urządzeń siedzi w tej jednej linii.
            session.setViewportActive(false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.enterBackground(); latchedTarget = nil }
        }
        .onChange(of: session.lastInjected) { _, injected in
            guard let injected else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            flash("Wklejono na Macu: \(injected.text.prefix(40))\(injected.text.count > 40 ? "…" : "")")
        }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .streaming:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .failed(let failure):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                flash(failure.message)
            default:
                break
            }
        }
    }

    // MARK: - Nagłówek

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.mac?.mac ?? "Mac")
                    .font(VFFont.display(18, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                Text(statusText)
                    .font(VFFont.mono(11))
                    .foregroundStyle(VFColor.muted)
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch session.transportState {
        case .connected: VFColor.text
        case .connecting: VFColor.muted
        default: VFColor.faint
        }
    }

    private var statusText: String {
        switch session.transportState {
        case .connected: "połączony · \(session.windows.count) okien"
        case .connecting: "łączę…"
        case .waiting(let retry): "ponawiam za \(Int(retry.rounded())) s"
        case .failed(let why): why
        case .idle: "rozłączony"
        }
    }

    /// Stan „bez konta". Parowanie po sieci lokalnej wyleciało (decyzja Wojtka
    /// 2026-08-12): wszystko idzie przez konto, więc jedyne, co tu można
    /// zrobić, to zalogować się w Ustawieniach.
    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zaloguj się kontem w Ustawieniach")
                .font(VFFont.body(15, weight: .semibold))
                .foregroundStyle(VFColor.text)
            Text("Telefon łączy się z Makiem przez to samo konto. Zaloguj się w zakładce Ustawienia — okna Maca pojawią się tutaj same.")
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brak terminali do pokazania")
                .font(VFFont.body(15, weight: .semibold))
                .foregroundStyle(VFColor.text)
            Text("Otwórz okno Terminala na Macu i sprawdź, czy VoiceFlow tam działa.")
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    // MARK: - Lista okien

    /// Podgląd całego ekranu Maca — jeden JPEG NA ŻĄDANIE (stuknięcie /
    /// przeciągnięcie w dół), nie strumień: oszczędza baterię i transfer,
    /// a układ pulpitu i tak nie zmienia się, gdy siedzisz przy telefonie.
    @ViewBuilder private var screenPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("EKRAN").vfEyebrow()
                Spacer()
                Button {
                    session.requestScreenshot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(VFColor.muted)
                }
            }
            if let data = session.screenshotJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
                    .onTapGesture { session.requestScreenshot() }
            } else if session.mac?.caps.screenshot == false {
                Text("Mac nie ma zgody „Nagrywanie ekranu” — włącz ją w Ustawieniach systemowych na Macu, wtedy zobaczysz tu podgląd pulpitu i tytuły okien.")
                    .font(VFFont.body(12))
                    .foregroundStyle(VFColor.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(VFColor.surfaceSolid)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            } else {
                Button {
                    session.requestScreenshot()
                } label: {
                    Text("Pobierz podgląd ekranu")
                        .font(VFFont.body(13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundStyle(VFColor.text)
                .background(VFColor.surfaceSolid)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            }
        }
    }

    /// Terminale z ostatniej migawki — jedyne okna, które tu pokazujemy.
    private var terminals: [WireWindow] {
        session.windows.filter(\.isTerminal)
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TERMINALE").vfEyebrow()
            VStack(spacing: 4) {
                ForEach(terminals) { window in
                    WindowRow(
                        window: window,
                        isSelected: window.id == session.selectedWindowID,
                        isTarget: window.id == activeTarget
                    )
                    // Tap TYLKO zaznacza cel po stronie telefonu — okno na
                    // Macu podnosi się dopiero przy starcie dyktowania
                    // (atomowy start z weryfikacją fokusu). Wcześniejsze
                    // „tap = podnieś od razu" przestawiało okna na Macu przy
                    // zwykłym przeglądaniu listy.
                    .contentShape(Rectangle())
                    .onTapGesture { session.select(windowID: window.id) }
                }
            }
        }
    }

    // MARK: - Pasek mówienia

    private var speakBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(targetLabel)
                    .font(VFFont.mono(11))
                    .foregroundStyle(VFColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if latchedTarget != nil {
                    Text("ZATRZASK")
                        .font(VFFont.mono(9))
                        .foregroundStyle(VFColor.background)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(VFColor.text)
                }
            }

            micButton

            if !displayedText.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text(displayedText)
                        .font(VFFont.body(13))
                        .foregroundStyle(session.rescuedText == nil ? VFColor.text : VFColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)

                    // Prompt w terminalu bez Entera zostaje w linii i nic się nie
                    // dzieje — dlatego zatwierdzenie jest osobnym, ŚWIADOMYM
                    // ruchem, a nie automatem po dyktowaniu.
                    Button("Wyślij ⏎") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        session.sendKey(.return_)
                        flash("Wysłano ⏎ do \(session.selectedWindow?.app ?? "okna")")
                    }
                    .buttonStyle(VFOutlineButtonStyle())
                    .disabled(session.phase.isBusy)
                }
            }

            // Każda akcja MUSI zostawić ślad na ekranie — bez tego nie widać,
            // czy stuknięcie w ogóle doszło (zgłoszone wprost: „chuj widać").
            if let toast {
                Text(toast)
                    .font(VFFont.mono(11))
                    .foregroundStyle(VFColor.muted)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1), alignment: .top)
    }

    private var micButton: some View {
        let recording = session.phase.isRecording
        return HStack(spacing: 10) {
            Circle()
                .fill(recording ? VFColor.text : VFColor.faint)
                .frame(width: 10, height: 10)
                .opacity(recording ? 1 : 0.6)
            Text(micLabel)
                .font(VFFont.body(15, weight: .semibold))
                .foregroundStyle(recording ? VFColor.background : VFColor.text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(recording ? VFColor.text : VFColor.background)
        .overlay(Rectangle().stroke(recording ? VFColor.text : VFColor.border, lineWidth: 1))
        .contentShape(Rectangle())
        // Ten sam gest co w pilocie: stuknięcie start/stop, przytrzymanie
        // „mów, póki trzymam". Dwuklik wyleciał z obu ekranów naraz, żeby
        // przycisk od mikrofonu zachowywał się wszędzie tak samo.
        .pushToTalkGesture(
            onTap: { toggleLatch(on: session.selectedWindow) },
            onHoldBegan: { beginHold(on: session.selectedWindow) },
            onHoldEnded: { endHold() }
        )
        .animation(.easeOut(duration: 0.12), value: recording)
    }

    private var micLabel: String {
        switch session.phase {
        case .failed(let failure): failure.message
        case .arming: "łączę z oknem…"
        case .streaming: latchedTarget == nil ? "mówisz — puść, aby wysłać" : "zatrzask — stuknij, aby zakończyć"
        case .finishing: "przetwarzam…"
        case .connecting: "łączę z Makiem…"
        case .offline: "zaloguj się kontem w Ustawieniach"
        case .ready: session.selectedWindow == nil ? "zaznacz terminal na liście" : "Mów — stuknij (start/stop) albo przytrzymaj"
        }
    }

    private var targetLabel: String {
        guard let window = session.windows.first(where: { $0.id == activeTarget }) ?? session.selectedWindow else {
            return "cel: nie wybrano"
        }
        return "cel: \(window.app) — \(window.displayTitle)"
    }

    /// Podgląd na żywo, a po nieudanym wstrzyknięciu — uratowany tekst, żeby
    /// wypowiedź nie zniknęła razem z komunikatem błędu.
    private var displayedText: String {
        session.rescuedText ?? session.previewText
    }

    private var activeTarget: String? {
        latchedTarget ?? session.selectedWindowID
    }

    // MARK: - Akcje

    private func beginHold(on window: WireWindow?) {
        guard let window else { return }
        session.select(windowID: window.id)
        session.beginDictation(target: window.id)
    }

    private func endHold() {
        // W trybie zatrzasku puszczenie palca NIE kończy wypowiedzi — o to
        // w zatrzasku chodzi.
        guard latchedTarget == nil else { return }
        session.endDictation()
    }

    /// Decyzja z FAZY SESJI, nie z lokalnej flagi — flaga potrafi się rozjechać
    /// (błąd z Maca, timeout, apka w tle) i wtedy stuknięcie przestaje kończyć
    /// wypowiedź, co jest najgorszym możliwym zachowaniem przycisku mikrofonu.
    private func toggleLatch(on window: WireWindow?) {
        if session.phase.isBusy {
            latchedTarget = nil
            session.endDictation()
            return
        }
        guard let window else { return }
        if latchedTarget != nil {
            latchedTarget = nil
            session.endDictation()
        } else {
            latchedTarget = window.id
            session.select(windowID: window.id)
            session.beginDictation(target: window.id)
        }
    }
}
