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
    /// Skaner QR parowania — dostępny WPROST z tej zakładki, nie z ustawień:
    /// parowanie to pierwsza rzecz, którą się tu robi, i pierwsza, którą
    /// trzeba naprawić, gdy połączenie nie działa.
    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !session.isPaired {
                    pairingCard
                } else if session.windows.isEmpty {
                    emptyState
                } else {
                    DesktopMapView(
                        windows: session.windows,
                        displays: session.displays,
                        screenshot: session.screenshotJPEG,
                        selectedID: session.selectedWindowID,
                        targetID: activeTarget,
                        onTap: { session.focus($0) },
                        onHoldBegan: { beginHold(on: $0) },
                        onHoldEnded: { _ in endHold() },
                        onDoubleTap: { toggleLatch(on: $0) },
                        onMove: { window, rect in
                            session.move(window, to: (x: rect.x, y: rect.y, w: rect.w, h: rect.h))
                        }
                    )

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showPairing = true
                    } label: {
                        Label("Sparuj z Makiem", systemImage: "qrcode.viewfinder")
                    }
                    if session.isPaired {
                        Button(role: .destructive) {
                            // Reset = zapomnij poświadczenia i od razu otwórz
                            // skaner — po resecie nie ma stanu pośredniego,
                            // w którym trzeba zgadywać, co dalej.
                            session.updateCredentials(nil)
                            latchedTarget = nil
                            showPairing = true
                        } label: {
                            Label("Zresetuj parowanie", systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
            }
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                PairingView(session: session)
                    .navigationTitle("Parowanie")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Anuluj") { showPairing = false }
                        }
                    }
            }
        }
        .onChange(of: session.isPaired) { _, paired in
            // Udany skan zamyka arkusz sam — użytkownik od razu widzi okna.
            if paired { showPairing = false }
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

    /// Stan „brak sparowanego Maca" — z przyciskiem, nie z odsyłaczem do
    /// ustawień.
    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brak sparowanego Maca")
                .font(VFFont.body(15, weight: .semibold))
                .foregroundStyle(VFColor.text)
            Text("Otwórz kod QR parowania na Macu i zeskanuj go tutaj. Telefon i Mac muszą być w tej samej sieci Wi-Fi.")
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
            Button {
                showPairing = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Sparuj z Makiem")
                        .font(VFFont.body(15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .foregroundStyle(VFColor.background)
            .background(VFColor.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brak okien do pokazania")
                .font(VFFont.body(15, weight: .semibold))
                .foregroundStyle(VFColor.text)
            Text("Sprawdź, czy VoiceFlow działa na Macu i ma włączone zdalne sterowanie w Ustawieniach.")
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    // MARK: - Lista okien

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OKNA").vfEyebrow()
            VStack(spacing: 4) {
                ForEach(session.windows) { window in
                    WindowRow(
                        window: window,
                        isSelected: window.id == session.selectedWindowID,
                        isTarget: window.id == activeTarget
                    )
                    .windowGestures(
                        onTap: { session.focus(window) },
                        onHoldBegan: { beginHold(on: window) },
                        onHoldEnded: { endHold() },
                        onDoubleTap: { toggleLatch(on: window) }
                    )
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
                    Button("Wyślij ⏎") { session.sendKey(.return_) }
                        .buttonStyle(VFOutlineButtonStyle())
                        .disabled(session.phase.isBusy)
                }
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
        .windowGestures(
            onTap: {},
            onHoldBegan: { beginHold(on: session.selectedWindow) },
            onHoldEnded: { endHold() },
            onDoubleTap: { toggleLatch(on: session.selectedWindow) }
        )
        .animation(.easeOut(duration: 0.12), value: recording)
    }

    private var micLabel: String {
        switch session.phase {
        case .failed(let failure): failure.message
        case .arming: "łączę z oknem…"
        case .streaming: latchedTarget == nil ? "mów — puść, aby wysłać" : "mów — dotknij dwa razy, aby zakończyć"
        case .finishing: "przetwarzam…"
        case .connecting: "łączę z Makiem…"
        case .offline: "brak sparowanego Maca"
        case .ready: session.selectedWindow == nil ? "wybierz okno" : "przytrzymaj, aby mówić"
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

    private func toggleLatch(on window: WireWindow?) {
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
