import AppKit
import SwiftUI

/// Obwódka rysowana NA oknie, którym steruje pilot z telefonu.
///
/// Po co: pilot jest do sterowania Makiem, przy którym się SIEDZI — patrzysz w
/// ekran, a telefon mówi tylko „terminal 7/8". Bez znacznika na ekranie i tak
/// nie wiadomo, który to jest, więc strzałki działają na ślepo (zgłoszone przez
/// Wojtka 2026-08-14).
///
/// Dwa poziomy jasności zamiast błysku albo stałej ramki:
///   • przez pierwsze `brightDuration` obwódka jest wyraźna + plakietka z
///     numerem — to jest odpowiedź na „który to teraz",
///   • potem przygasa do cienkiej linii i ZOSTAJE, dopóki pilot celuje w to
///     okno — dzięki temu wiesz to też po dziesięciu sekundach, a jednocześnie
///     nie masz na stałe jaskrawej ramki na pół ekranu.
///
/// Panel NIGDY nie staje się oknem kluczowym i nie łapie kliknięć — inaczej
/// odbierałby fokus terminalowi, do którego przed chwilą sam celował, i całe
/// wstrzykiwanie tekstu przestałoby trafiać (ta sama landmina co w `PillPanel`).
@MainActor
final class WindowHighlighter {

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Jak długo obwódka świeci pełną jasnością, zanim przygaśnie.
    var brightDuration: TimeInterval = 1.8
    /// Po tylu sekundach bez ruchu z pilota znacznik znika sam — żeby nie
    /// zostawał na ekranie do końca dnia po jednej sesji z telefonu.
    var idleTimeout: TimeInterval = 120

    private var panel: Panel?
    private var dimTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private(set) var highlightedWindowID: String?

    /// `frame` w układzie CGWindowList (początek w LEWYM GÓRNYM rogu ekranu
    /// głównego), czyli dokładnie tak, jak przychodzi w `WireWindow`.
    func show(windowID: String, frame: CGRect, label: String) {
        guard let flipped = Self.screenRect(for: frame) else { return }
        highlightedWindowID = windowID

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(flipped, display: true)
        panel.contentView = NSHostingView(rootView: WindowHighlightView(label: label))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dimTask?.cancel()
        dimTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.brightDuration ?? 1.8) * 1_000_000_000))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            panel.animator().alphaValue = 0.32
        }

        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 120) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dimTask?.cancel(); dimTask = nil
        expiryTask?.cancel(); expiryTask = nil
        highlightedWindowID = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> Panel {
        let panel = Panel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }

    /// Przeliczenie z układu CGWindowList (Y rośnie w dół, początek w lewym
    /// górnym rogu ekranu głównego) na układ AppKitu (Y rośnie w górę, początek
    /// w lewym dolnym rogu ekranu głównego). Ta sama zamiana co
    /// `PillWindowController.moveOverWindow` — działa też dla okien na drugim
    /// monitorze, bo oba układy mają wspólny punkt odniesienia w ekranie
    /// głównym.
    static func screenRect(for frame: CGRect, primaryHeight: CGFloat? = nil) -> CGRect? {
        guard let height = primaryHeight ?? NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(
            x: frame.origin.x,
            y: height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

private struct WindowHighlightView: View {
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dwie obwódki: jasna w środku, ciemna na zewnątrz. Sama biała
            // ramka ginie na jasnym tle terminala, sama ciemna — na ciemnym.
            Rectangle()
                .strokeBorder(Color.black.opacity(0.55), lineWidth: 6)
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 3)
                .padding(1.5)

            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white)
                .padding(10)
        }
        .allowsHitTesting(false)
    }
}
