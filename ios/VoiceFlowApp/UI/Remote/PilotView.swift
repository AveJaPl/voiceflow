import SwiftUI

/// Zakładka „Pilot": telefon jako pięcioprzyciskowa klawiatura do Maca.
///
/// PO CO OSOBNY EKRAN, skoro jest już zakładka „Mac": tamta służy do PATRZENIA
/// — podgląd pulpitu, lista okien, treść terminala. Pilot służy do KLIKANIA
/// nie patrząc: wielkie pola, stała pozycja, wszystko w zasięgu kciuka, zero
/// przewijania. Dlatego układ jest sztywny i nic tu nie dochodzi „na potem" —
/// przycisk, który zmienia położenie między wejściami, przestaje być pilotem.
///
/// CO ROBIĄ PRZYCISKI (wszystkie działają na ZAZNACZONYM terminalu, a Mac
/// podnosi go i weryfikuje przed każdym naciśnięciem — patrz `RemoteControlHub`
/// obsługa `.key`):
///   ◀ ▶      — przeskok fokusu po terminalach w stałej kolejności ekranowej,
///   MÓW      — przytrzymaj (mówisz póki trzymasz) albo STUKNIJ raz
///              (start/stop). Dwuklik wyleciał: dawał się włączyć, ale nie
///              dawał wyłączyć — patrz `PushToTalkGesture`.
///   ⏎        — zatwierdzenie promptu, bez tego tekst zostaje w linii,
///   PULPIT ◀ ▶ — przeskok między pulpitami (jak trzy palce po gładziku),
///   COFNIJ   — w terminalu ⌃U (czyszczenie linii), poza nim ⌘Z,
///   WKLEJ    — ⌘V ze SCHOWKA MACA; telefon nie przesyła tu żadnej treści.
struct PilotView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var latched = false
    @State private var toast: String?
    @State private var toastToken = 0

    var body: some View {
        VStack(spacing: 12) {
            targetBar
            padRow
            actionRow
            desktopRow
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VFColor.background)
        .navigationTitle("Pilot")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.connect()
            session.setViewportActive(true)
            // Bez zaznaczenia każdy przycisk byłby martwy — pierwszy terminal
            // bierzemy sami, tak samo jak w zakładce „Mac".
            if session.selectedWindowID == nil {
                session.select(windowID: TerminalOrder.sorted(session.windows).first?.id)
            }
        }
        .onDisappear { session.setViewportActive(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.enterBackground(); latched = false }
        }
        .onChange(of: session.lastInjected) { _, injected in
            guard let injected else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            flash("wklejono: \(injected.text.prefix(32))\(injected.text.count > 32 ? "…" : "")")
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

    // MARK: - Nagłówek celu

    private var terminals: [WireWindow] { TerminalOrder.sorted(session.windows) }

    private var position: String {
        guard let id = session.selectedWindowID,
              let index = terminals.firstIndex(where: { $0.id == id }) else { return "—" }
        return "\(index + 1)/\(terminals.count)"
    }

    private var targetBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.selectedWindow?.focused == true ? VFColor.text : VFColor.faint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.selectedWindow?.displayTitle ?? "brak terminala")
                    .font(VFFont.display(17, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(VFFont.mono(11))
                    .foregroundStyle(VFColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(position)
                .font(VFFont.mono(12))
                .foregroundStyle(VFColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private var subtitle: String {
        switch session.phase {
        case .streaming: latched ? "zatrzask — stuknij MÓW, aby skończyć" : "mówisz — puść, aby wysłać"
        case .arming: "podnoszę okno…"
        case .finishing: "przetwarzam…"
        case .connecting: "łączę z Makiem…"
        case .offline: "zaloguj się kontem w Ustawieniach"
        case .failed(let failure): failure.message
        case .ready: session.selectedWindow.map { _ in "stuknij = start/stop · przytrzymaj = mów" } ?? "otwórz terminal na Macu"
        }
    }

    // MARK: - Pad

    private var padRow: some View {
        HStack(spacing: 12) {
            PadButton(glyph: "chevron.left", caption: "TERMINAL") { step(-1) }
                .frame(width: 84)
            micPad
            PadButton(glyph: "chevron.right", caption: "TERMINAL") { step(1) }
                .frame(width: 84)
        }
        .frame(maxHeight: .infinity)
    }

    private var micPad: some View {
        let recording = session.phase.isRecording
        return VStack(spacing: 8) {
            Image(systemName: recording ? "waveform" : "mic")
                .font(.system(size: 34, weight: .regular))
            Text(recording ? (latched ? "STUKNIJ, BY SKOŃCZYĆ" : "MÓWISZ") : "MÓW")
                .font(VFFont.mono(11))
        }
        .foregroundStyle(recording ? VFColor.background : VFColor.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(recording ? VFColor.text : VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(recording ? VFColor.text : VFColor.border, lineWidth: 1))
        .contentShape(Rectangle())
        .pushToTalkGesture(
            onTap: { toggleLatch() },
            onHoldBegan: { beginHold() },
            onHoldEnded: { endHold() }
        )
        .animation(.easeOut(duration: 0.12), value: recording)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            PadButton(glyph: "return", caption: "WYŚLIJ") {
                key(.return_, label: "⏎")
            }
            PadButton(glyph: "arrow.uturn.backward", caption: "COFNIJ") {
                let isTerminal = session.selectedWindow?.isTerminal ?? true
                key(isTerminal ? .ctrlU : .cmdZ, label: isTerminal ? "⌃U" : "⌘Z")
            }
            PadButton(glyph: "doc.on.clipboard", caption: "WKLEJ") {
                key(.cmdV, label: "⌘V")
            }
        }
        .frame(height: 96)
    }

    /// Przeskok między pulpitami — to samo, co przesunięcie trzema palcami po
    /// gładziku. Bez tego terminale stojące na innym pulpicie są z telefonu
    /// nieosiągalne, choć widać je na liście.
    private var desktopRow: some View {
        HStack(spacing: 12) {
            PadButton(glyph: "arrow.left.to.line", caption: "PULPIT") {
                desktop(.ctrlLeft, label: "pulpit w lewo")
            }
            PadButton(glyph: "arrow.right.to.line", caption: "PULPIT") {
                desktop(.ctrlRight, label: "pulpit w prawo")
            }
        }
        .frame(height: 64)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            SmallKeyButton(title: "ESC") { key(.escape, label: "esc") }
            SmallKeyButton(title: "PRZERWIJ ⌃C") { key(.ctrlC, label: "⌃C") }
            Spacer()
            // Każde stuknięcie MUSI zostawić ślad na ekranie — bez tego nie
            // widać, czy w ogóle doszło (zgłoszone wprost: „chuj widać").
            Text(toast ?? statusText)
                .font(VFFont.mono(11))
                .foregroundStyle(toast == nil ? VFColor.faint : VFColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var statusText: String {
        switch session.transportState {
        case .connected: "połączony · \(terminals.count) terminali"
        case .connecting: "łączę…"
        case .waiting(let retry): "ponawiam za \(Int(retry.rounded())) s"
        case .failed(let why): why
        case .idle: "rozłączony"
        }
    }

    // MARK: - Akcje

    private func step(_ offset: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let window = session.stepTerminal(offset) else {
            flash("brak terminali")
            return
        }
        flash("cel: \(window.displayTitle)")
    }

    /// Zmiana pulpitu leci BEZ celu: podniesienie okna przed naciśnięciem
    /// przerzuciłoby nas z powrotem na pulpit tego okna.
    private func desktop(_ chord: KeyChord, label: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        session.sendKey(chord, toSelectedWindow: false)
        flash(label)
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

    /// Decyzja opiera się na STANIE SESJI, nie na lokalnej fladze `latched`.
    /// Flaga potrafi się rozjechać z rzeczywistością (błąd z Maca, timeout,
    /// apka w tle) i wtedy stuknięcie w mikrofon przestawało cokolwiek robić —
    /// dokładnie to zgłosił Wojtek. Nagrywamy? To stuknięcie kończy. Kropka.
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

/// Duże pole pilota. Bez `Button`, bo `Button` w siatce przycisków reaguje
/// dopiero po puszczeniu palca i przy szybkim klikaniu gubi stuknięcia —
/// `onTapGesture` z własnym podświetleniem jest tu wyraźnie żwawszy.
private struct PadButton: View {
    let glyph: String
    let caption: String
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 24, weight: .regular))
            Text(caption)
                .font(VFFont.mono(10))
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

private struct SmallKeyButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VFFont.mono(11))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .foregroundStyle(VFColor.muted)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }
}
