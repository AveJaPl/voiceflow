import SwiftUI

/// JEDEN ekran sterowania Makiem. Bez trybów (decyzja Wojtka 2026-08-14:
/// „nie ma co rozdzielenia na klawiaturę albo pilot"), z podglądem pulpitu
/// ZAWSZE na wierzchu — bo to jest ten element, po którym naprawdę się celuje.
///
/// PIONOWO: podgląd pulpitu, pod nim lista terminali (stuknięcie rozwija
/// podsumowanie z ostatnimi liniami), na dole zwarty pad.
/// POZIOMO: podgląd zajmuje cały lewy bok, pad chowa się w wąskiej kolumnie z
/// prawej. Lista znika, bo w tym układzie listą JEST podgląd — okna stukasz
/// bezpośrednio.
///
/// Zaznaczony terminal świeci w DWÓCH miejscach naraz: obwódką na ekranie Maca
/// i ramką na podglądzie w telefonie. Jedno bez drugiego znaczy, że przy Macu
/// wiadomo, co jest zaznaczone, a w telefonie nie — albo odwrotnie.
struct MacControlView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var latched = false
    @State private var expandedTerminal: String?
    @State private var toast: String?
    @State private var toastToken = 0

    /// Telefon położony poziomo = tryb „patrzę na ekran Maca".
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if !session.isPaired {
                VStack(spacing: 12) { header; signInCard; Spacer() }
            } else if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VFColor.background)
        .navigationTitle("Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
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

    // MARK: - Układy

    private var portraitLayout: some View {
        VStack(spacing: 8) {
            header
            if session.mac?.caps.screenshot == false { permissionHint }
            preview
                .frame(height: 200)
            terminalList
            pad
            statusLine
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: 10) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 6) {
                compactHeader
                pad
                statusLine
            }
            .frame(width: 210)
        }
    }

    // MARK: - Nagłówek

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.mac?.mac ?? "Mac")
                    .font(VFFont.body(14, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                    .lineLimit(1)
                Text(targetLabel)
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let spaces = session.spaces {
                Text("PULPIT \(spaces.index)/\(spaces.count)")
                    .font(VFFont.mono(9))
                    .foregroundStyle(VFColor.muted)
            }
        }
    }

    /// W poziomie nagłówek musi zmieścić się w wąskiej kolumnie, więc zostaje
    /// sama kropka stanu i cel.
    private var compactHeader: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(targetLabel)
                .font(VFFont.mono(9))
                .foregroundStyle(VFColor.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var targetLabel: String {
        guard let selected = session.selectedWindow,
              let index = terminals.firstIndex(where: { $0.id == selected.id }) else {
            return "brak zaznaczonego terminala"
        }
        return "\(index + 1)/\(terminals.count) · \(TerminalTitle.short(selected.title) ?? selected.app)"
    }

    private var statusColor: Color {
        switch session.transportState {
        case .connected: VFColor.text
        case .connecting: VFColor.muted
        default: VFColor.faint
        }
    }

    // MARK: - Podgląd

    private var terminals: [WireWindow] { TerminalOrder.sorted(session.windows) }

    @ViewBuilder private var preview: some View {
        if let data = session.screenshotJPEG, let image = UIImage(data: data) {
            MacScreenPreview(
                image: image,
                area: session.screenshotArea,
                terminals: terminals,
                selectedID: session.selectedWindowID,
                onSelect: { pick($0) }
            )
        } else {
            VStack(spacing: 8) {
                Text(session.mac?.caps.screenshot == false
                     ? "Brak zgody „Nagrywanie ekranu” na Macu"
                     : "Czekam na podgląd pulpitu…")
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
                Button("Odśwież") { session.requestScreenshot() }
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VFColor.surfaceSolid)
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        }
    }

    /// Stuknięcie w okno na podglądzie = przeniesienie fokusu na Macu. Tego
    /// właśnie się od podglądu oczekuje: widzisz okno, stukasz, jest na wierzchu.
    private func pick(_ window: WireWindow) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.focus(window)
        expandedTerminal = window.id
        flash("cel: \(TerminalTitle.short(window.title) ?? window.app)")
    }

    // MARK: - Lista terminali (tylko pionowo)

    private var terminalList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TERMINALE \(terminals.count)").vfEyebrow()
            ScrollView {
                VStack(spacing: 4) {
                    if terminals.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                            TerminalCard(
                                index: index + 1,
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
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text(session.transportState == .connected
             ? "Mac nie zgłasza żadnego terminala."
             : "Czekam na połączenie z Makiem…")
            .font(VFFont.body(12))
            .foregroundStyle(VFColor.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(VFColor.surfaceSolid)
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private func tap(_ terminal: WireWindow) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        session.select(windowID: terminal.id)
        expandedTerminal = expandedTerminal == terminal.id ? nil : terminal.id
    }

    private var permissionHint: some View {
        Text("Mac nie ma zgody „Nagrywanie ekranu” — bez niej nie ma podglądu ani nazw terminali. Ustawienia systemowe → Prywatność → Nagrywanie ekranu → VoiceFlow, potem uruchom aplikację na Macu ponownie.")
            .font(VFFont.mono(9))
            .foregroundStyle(VFColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(VFColor.surfaceSolid)
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    // MARK: - Pad

    private var pad: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                PadKey(glyph: "chevron.left", caption: nil, small: true) { step(-1) }
                micKey
                PadKey(glyph: "chevron.right", caption: nil, small: true) { step(1) }
            }
            .frame(height: isLandscape ? 50 : 56)

            HStack(spacing: 5) {
                PadKey(glyph: "return", caption: "WYŚLIJ", small: true) { key(.return_, label: "⏎") }
                PadKey(glyph: "arrow.uturn.backward", caption: "COFNIJ", small: true) {
                    let isTerminal = session.selectedWindow?.isTerminal ?? true
                    key(isTerminal ? .ctrlU : .cmdZ, label: isTerminal ? "⌃U" : "⌘Z")
                }
                PadKey(glyph: "doc.on.clipboard", caption: "WKLEJ", small: true) { key(.cmdV, label: "⌘V") }
                PadKey(glyph: "escape", caption: "ESC", small: true) { key(.escape, label: "esc") }
            }
            .frame(height: 44)

            HStack(spacing: 5) {
                PadKey(glyph: "arrow.left.square", caption: "PULPIT", small: true) { desktop(-1, label: "pulpit w lewo") }
                PadKey(glyph: "arrow.right.square", caption: "PULPIT", small: true) { desktop(1, label: "pulpit w prawo") }
                PadKey(glyph: "xmark.octagon", caption: "PRZERWIJ", small: true) { key(.ctrlC, label: "⌃C") }
            }
            .frame(height: 44)
        }
    }

    private var micKey: some View {
        let recording = session.phase.isRecording
        return VStack(spacing: 3) {
            Image(systemName: recording ? "waveform" : "mic")
                .font(.system(size: 19, weight: .regular))
            Text(micCaption)
                .font(VFFont.mono(8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        case .arming: "PODNOSZĘ"
        case .streaming: latched ? "STUKNIJ, BY SKOŃCZYĆ" : "MÓWISZ"
        case .finishing: "PRZETWARZAM"
        default: "MÓW"
        }
    }

    // MARK: - Pasek stanu

    private var statusLine: some View {
        Text(toast ?? defaultStatus)
            .font(VFFont.mono(9))
            .foregroundStyle(toast == nil ? VFColor.faint : VFColor.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultStatus: String {
        switch session.transportState {
        case .connected: "połączony · \(terminals.count) terminali"
        case .connecting: "łączę…"
        case .waiting(let retry): "ponawiam za \(Int(retry.rounded())) s"
        case .failed(let why): why
        case .idle: "rozłączony"
        }
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

/// Wiersz terminala: numer TEN SAM co na podglądzie, nazwa sesji, stan. Po
/// stuknięciu rozwija się w podsumowanie z ostatnimi liniami.
private struct TerminalCard: View {
    let index: Int
    let terminal: WireWindow
    let isSelected: Bool
    let isExpanded: Bool
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                    Text("Podgląd treści Mac czyta tylko dla zaznaczonego okna Terminala.")
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
        .padding(.vertical, 7)
        .background(isSelected ? VFColor.surfaceSolid : VFColor.surfaceSolid.opacity(0.55))
        .overlay(Rectangle().stroke(isSelected ? VFColor.text.opacity(0.5) : VFColor.border, lineWidth: 1))
    }
}

/// Klawisz pada. Reaguje na DOTKNIĘCIE, nie na puszczenie: `Button` przy
/// szybkim stukaniu gubi zdarzenia, a pilot ma odpowiadać natychmiast.
private struct PadKey: View {
    let glyph: String
    let caption: String?
    let small: Bool
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: glyph)
                .font(.system(size: small ? 15 : 19, weight: .regular))
            if let caption {
                Text(caption)
                    .font(VFFont.mono(8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
