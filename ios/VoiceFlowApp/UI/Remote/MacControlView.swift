import SwiftUI

/// JEDEN ekran sterowania Makiem, w dwóch trybach (scalenie „Mac" + „Pilot",
/// decyzja Wojtka 2026-08-14). Dwie osobne zakładki znaczyły dwa różne wyglądy
/// i dwa różne zachowania tego samego przycisku — a to jest jeden sprzęt i
/// jedna sesja.
///
/// TRYBY:
///   • KLAWIATURA — jesteś przy Macu (ten sam Wi-Fi). Liczy się szybkość:
///     terminale, mikrofon, klawisze. Bez podglądu ekranu, bo patrzysz na
///     ekran, a każdy zrzut to kilkaset kilobajtów przez serwer.
///   • PILOT — jesteś poza domem. Dochodzi podgląd pulpitu i przełączanie
///     pulpitów, czyli wszystko, czego nie da się zobaczyć własnymi oczami.
///
/// Tryb wybiera się SAM: telefon porównuje swoją podsieć z adresami, które Mac
/// przysyła w `hello` (`LocalNetwork`). Wyjście z domowego Wi-Fi przestawia go
/// bez pytania. Ręczny wybór ma pierwszeństwo, ale tylko do najbliższej zmiany
/// sieci — inaczej jedno stuknięcie sprzed tygodnia zostawałoby na zawsze.
///
/// UKŁAD (ten sam na małym i dużym telefonie): góra to PATRZENIE — lista
/// terminali, po stuknięciu rozwinięta w podsumowanie z ostatnimi liniami. Dół
/// to KLIKANIE — zwarty pad, przyciski o połowę niższe niż w pierwszej wersji
/// pilota, w stałych miejscach.
struct MacControlView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.scenePhase) private var scenePhase

    enum Mode: String { case keyboard, remote }

    /// Ręczny wybór trybu i sieć, w której zapadł. Zapisany w tej samej sieci
    /// obowiązuje; po zmianie sieci wraca automat.
    @AppStorage("voiceflow.mode.manual") private var manualModeRaw = ""
    @AppStorage("voiceflow.mode.manualNetwork") private var manualModeNetwork = ""

    @State private var latched = false
    @State private var expandedTerminal: String?
    @State private var toast: String?
    @State private var toastToken = 0

    var body: some View {
        VStack(spacing: 10) {
            header
            if !session.isPaired {
                signInCard
                Spacer()
            } else {
                if session.mac?.caps.screenshot == false {
                    permissionHint
                }
                terminalPane
                pad
            }
            statusLine
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VFColor.background)
        .navigationTitle("Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.connect()
            session.setViewportActive(true)
            if session.selectedWindowID == nil {
                session.select(windowID: TerminalOrder.sorted(session.windows).first?.id)
            }
        }
        .onDisappear { session.setViewportActive(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.wakeUp()
            } else {
                session.enterBackground()
                latched = false
            }
        }
        .onChange(of: session.windows) { _, windows in
            if session.selectedWindowID == nil {
                session.select(windowID: TerminalOrder.sorted(windows).first?.id)
            }
        }
        .onChange(of: session.lastInjected) { _, injected in
            guard let injected else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            flash("wklejono: \(injected.text.prefix(30))\(injected.text.count > 30 ? "…" : "")")
        }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .streaming: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .failed(let failure):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                latched = false
                flash(failure.message)
            default: break
            }
        }
    }

    // MARK: - Tryb

    /// Klucz sieci, w której zapadł ręczny wybór. `-` gdy jeszcze nie wiadomo.
    private var networkKey: String {
        switch session.isOnMacNetwork {
        case true: "dom"
        case false: "poza"
        case nil: "-"
        }
    }

    private var mode: Mode {
        if manualModeNetwork == networkKey, let manual = Mode(rawValue: manualModeRaw) {
            return manual
        }
        return session.isOnMacNetwork == true ? .keyboard : .remote
    }

    private func setMode(_ new: Mode) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        manualModeRaw = new.rawValue
        manualModeNetwork = networkKey
        // Podgląd pulpitu ma sens tylko w pilocie — subskrypcja idzie za trybem,
        // żeby w trybie klawiatury nie płacić za nic transferem.
        if new == .remote { session.requestScreenshot() }
    }

    // MARK: - Nagłówek

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.mac?.mac ?? "Mac")
                    .font(VFFont.body(14, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                    .lineLimit(1)
                Text(networkLabel)
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
            }
            Spacer(minLength: 8)
            modeSwitch
        }
    }

    private var networkLabel: String {
        switch session.isOnMacNetwork {
        case true: "ta sama sieć — tryb wybrany automatycznie"
        case false: "poza siecią Maca — tryb wybrany automatycznie"
        case nil: "sieć nieznana"
        }
    }

    /// Dwa pola zamiast `Picker`: `Picker` w stylu segmentowym ignoruje własne
    /// fonty i kolory, a ten ekran ma wyglądać jak reszta aplikacji.
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeTab("KLAWIATURA", .keyboard)
            modeTab("PILOT", .remote)
        }
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private func modeTab(_ title: String, _ value: Mode) -> some View {
        let active = mode == value
        return Text(title)
            .font(VFFont.mono(9))
            .tracking(0.6)
            .foregroundStyle(active ? VFColor.background : VFColor.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(active ? VFColor.text : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { setMode(value) }
    }

    private var statusColor: Color {
        switch session.transportState {
        case .connected: VFColor.text
        case .connecting: VFColor.muted
        default: VFColor.faint
        }
    }

    // MARK: - Górna połowa: terminale (i pulpit w trybie pilota)

    private var terminals: [WireWindow] { TerminalOrder.sorted(session.windows) }

    @ViewBuilder private var terminalPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TERMINALE \(terminals.count)").vfEyebrow()
                Spacer()
                if mode == .remote {
                    Button {
                        session.requestScreenshot()
                        flash("pobieram podgląd ekranu")
                    } label: {
                        Text("EKRAN")
                            .font(VFFont.mono(9))
                            .foregroundStyle(VFColor.muted)
                    }
                }
            }

            ScrollView {
                VStack(spacing: 4) {
                    if mode == .remote, let data = session.screenshotJPEG, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
                            .onTapGesture { session.requestScreenshot() }
                    }

                    if terminals.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                            TerminalCard(
                                index: index + 1,
                                total: terminals.count,
                                terminal: terminal,
                                isSelected: terminal.id == session.selectedWindowID,
                                isExpanded: expandedTerminal == terminal.id,
                                lines: terminal.id == session.selectedWindowID ? session.terminalLines : []
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { tap(terminal) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text(session.transportState == .connected
             ? "Mac nie zgłasza żadnego terminala. Otwórz okno Terminala."
             : "Czekam na połączenie z Makiem…")
            .font(VFFont.body(12))
            .foregroundStyle(VFColor.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(VFColor.surfaceSolid)
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    /// Stuknięcie ZAZNACZA i rozwija podsumowanie. Podniesienie okna na Macu
    /// idzie osobno (strzałki, start dyktowania), bo samo przeglądanie listy
    /// nie ma przestawiać okien pod ręką Wojtka.
    private func tap(_ terminal: WireWindow) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        session.select(windowID: terminal.id)
        expandedTerminal = expandedTerminal == terminal.id ? nil : terminal.id
    }

    // MARK: - Dolna część: pad

    private var pad: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                PadKey(glyph: "chevron.left", caption: nil, wide: false) { step(-1) }
                micKey
                PadKey(glyph: "chevron.right", caption: nil, wide: false) { step(1) }
            }
            .frame(height: 58)

            HStack(spacing: 6) {
                PadKey(glyph: "return", caption: "WYŚLIJ", wide: true) { key(.return_, label: "⏎") }
                PadKey(glyph: "arrow.uturn.backward", caption: "COFNIJ", wide: true) {
                    let isTerminal = session.selectedWindow?.isTerminal ?? true
                    key(isTerminal ? .ctrlU : .cmdZ, label: isTerminal ? "⌃U" : "⌘Z")
                }
                PadKey(glyph: "doc.on.clipboard", caption: "WKLEJ", wide: true) { key(.cmdV, label: "⌘V") }
                PadKey(glyph: "escape", caption: "ESC", wide: true) { key(.escape, label: "esc") }
            }
            .frame(height: 46)

            if mode == .remote {
                HStack(spacing: 6) {
                    PadKey(glyph: "rectangle.portrait.and.arrow.forward", caption: "PULPIT ◀", wide: true) {
                        desktop(-1, label: "pulpit w lewo")
                    }
                    PadKey(glyph: "rectangle.portrait.and.arrow.right", caption: "PULPIT ▶", wide: true) {
                        desktop(1, label: "pulpit w prawo")
                    }
                    PadKey(glyph: "xmark.octagon", caption: "PRZERWIJ", wide: true) { key(.ctrlC, label: "⌃C") }
                }
                .frame(height: 46)
            }
        }
    }

    private var micKey: some View {
        let recording = session.phase.isRecording
        return VStack(spacing: 3) {
            Image(systemName: recording ? "waveform" : "mic")
                .font(.system(size: 20, weight: .regular))
            Text(micCaption)
                .font(VFFont.mono(9))
                .lineLimit(1)
        }
        .foregroundStyle(recording ? VFColor.background : VFColor.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(recording ? VFColor.text : VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(recording ? VFColor.text : VFColor.border, lineWidth: 1))
        .pushToTalkGesture(
            onTap: { toggleLatch() },
            onHoldBegan: { beginHold() },
            onHoldEnded: { endHold() }
        )
        .animation(.easeOut(duration: 0.12), value: recording)
    }

    private var micCaption: String {
        switch session.phase {
        case .arming: "PODNOSZĘ OKNO"
        case .streaming: latched ? "STUKNIJ, BY SKOŃCZYĆ" : "MÓWISZ"
        case .finishing: "PRZETWARZAM"
        default: "MÓW"
        }
    }

    // MARK: - Pasek stanu

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(toast ?? spacesLabel ?? defaultStatus)
                .font(VFFont.mono(10))
                .foregroundStyle(toast == nil ? VFColor.faint : VFColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var defaultStatus: String {
        switch session.transportState {
        case .connected:
            if let target = session.selectedWindow {
                return "cel: \(TerminalTitle.short(target.title) ?? target.app)"
            }
            return "połączony"
        case .connecting: return "łączę…"
        case .waiting(let retry): return "ponawiam za \(Int(retry.rounded())) s"
        case .failed(let why): return why
        case .idle: return "rozłączony"
        }
    }

    /// Brak zgody „Nagrywanie ekranu" na Macu jest widoczny WYŁĄCZNIE tutaj:
    /// macOS bez niej nie oddaje tytułów okien ani zrzutu, więc lista terminali
    /// robi się bezimienna, a podgląd pusty. To wygląda jak zepsuta apka, a
    /// jest jedną zgodą do kliknięcia.
    private var permissionHint: some View {
        Text("Mac nie ma zgody „Nagrywanie ekranu” — stąd terminale bez nazw i brak podglądu. Ustawienia systemowe → Prywatność → Nagrywanie ekranu → VoiceFlow, potem uruchom aplikację na Macu ponownie.")
            .font(VFFont.mono(9))
            .foregroundStyle(VFColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(VFColor.surfaceSolid)
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zaloguj się kontem w Ustawieniach")
                .font(VFFont.body(15, weight: .semibold))
                .foregroundStyle(VFColor.text)
            Text("Telefon i Mac spotykają się przez to samo konto — po zalogowaniu terminale pojawią się tutaj same.")
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    // MARK: - Akcje

    private func step(_ offset: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let window = session.stepTerminal(offset) else {
            flash("brak terminali")
            return
        }
        expandedTerminal = window.id
        flash("cel: \(TerminalTitle.short(window.title) ?? window.app)")
    }

    private func key(_ chord: KeyChord, label: String) {
        guard session.selectedWindowID != nil else {
            flash("najpierw wybierz terminal")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.sendKey(chord)
        flash("wysłano \(label)")
    }

    private func desktop(_ offset: Int, label: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        session.stepSpace(offset)
        flash(label)
    }

    /// Mac odsyła pozycję pulpitu po każdej zmianie — bez tego przycisk
    /// wygląda identycznie, gdy zadziałał i gdy nie.
    private var spacesLabel: String? {
        guard let spaces = session.spaces else { return nil }
        return "pulpit \(spaces.index)/\(spaces.count)"
    }

    private func beginHold() {
        guard let id = session.selectedWindowID else {
            flash("najpierw wybierz terminal")
            return
        }
        session.beginDictation(target: id)
    }

    private func endHold() {
        guard !latched else { return }
        session.endDictation()
    }

    /// Decyzja z FAZY SESJI, nie z lokalnej flagi — flaga rozjeżdża się przy
    /// błędzie Maca, timeoucie i zejściu apki w tło, a wtedy stuknięcie
    /// przestaje kończyć wypowiedź.
    private func toggleLatch() {
        if session.phase.isBusy {
            latched = false
            session.endDictation()
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }
        guard let id = session.selectedWindowID else {
            flash("najpierw wybierz terminal")
            return
        }
        latched = true
        session.beginDictation(target: id)
    }

    private func flash(_ message: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard token == toastToken else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

/// Wiersz terminala: numer, nazwa sesji, kropka aktywności. Po stuknięciu
/// rozwija się w podsumowanie z ostatnimi liniami — na telefonie to jedyny
/// sposób, żeby wiedzieć, CO tam się dzieje, bez podglądu całego ekranu.
private struct TerminalCard: View {
    let index: Int
    let total: Int
    let terminal: WireWindow
    let isSelected: Bool
    let isExpanded: Bool
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(VFFont.mono(10))
                    .foregroundStyle(isSelected ? VFColor.background : VFColor.muted)
                    .frame(width: 18, height: 18)
                    .background(isSelected ? VFColor.text : VFColor.border.opacity(0.4))

                Text(TerminalTitle.short(terminal.title) ?? "Terminal \(index)")
                    .font(VFFont.body(13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(VFColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if terminal.focused {
                    Text("NA WIERZCHU")
                        .font(VFFont.mono(8))
                        .foregroundStyle(VFColor.faint)
                }
            }

            if isExpanded {
                if lines.isEmpty {
                    Text("Brak podglądu treści — Mac czyta ją tylko z Terminala, i tylko dla zaznaczonego okna.")
                        .font(VFFont.mono(9))
                        .foregroundStyle(VFColor.faint)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(VFFont.mono(9))
                                .foregroundStyle(VFColor.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? VFColor.surfaceSolid : VFColor.surfaceSolid.opacity(0.55))
        .overlay(Rectangle().stroke(isSelected ? VFColor.text.opacity(0.5) : VFColor.border, lineWidth: 1))
    }
}

/// Klawisz pada. Reaguje na DOTKNIĘCIE, nie na puszczenie: `Button` przy
/// szybkim stukaniu gubi zdarzenia, a pilot ma odpowiadać natychmiast.
private struct PadKey: View {
    let glyph: String
    let caption: String?
    let wide: Bool
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: glyph)
                .font(.system(size: wide ? 15 : 19, weight: .regular))
            if let caption {
                Text(caption)
                    .font(VFFont.mono(8))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(pressed ? VFColor.background : VFColor.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pressed ? VFColor.text : VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(pressed ? VFColor.text : VFColor.border, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                }
                .onEnded { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.1), value: pressed)
    }
}
