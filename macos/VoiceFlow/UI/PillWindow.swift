import AppKit
import SwiftUI
import Combine

/// Panel hostujący pill. Wymaganie techniczne bez którego cała aplikacja nie
/// działa: NIGDY nie może stać się key window, inaczej aplikacja docelowa
/// traci fokus i dyktowanie nie ma gdzie pisać.
///
/// `.nonactivatingPanel` w stylu + `canBecomeKey = false` to podwójne
/// zabezpieczenie — pierwsze mówi AppKitowi żeby nie aktywował panelu przy
/// pokazaniu, drugie odmawia fokusu nawet gdyby ktoś kliknął w pill.
final class PillPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // cień daje SwiftUI (PillView), żeby nie dublować się z panelem
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Przeciąganie za tło pilla (feedback Wojtka 2026-08-09) — bez modyfikatora,
        // jak w każdym zwykłym oknie z paskiem tytułu, tylko że tu cała karta jest "paskiem".
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none // własne animacje wjazdu robi PillView, panel się nie ma dublować
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Właściciel cyklu życia panelu + pozycjonowania.
///
/// Redesign 2026-08-09: PillView jest teraz kartą (VStack, tekst zawijany na
/// kilka linii, `.result` ze scrollem) — jej naturalny rozmiar zależy od
/// TREŚCI (długość tekstu), nie tylko od fazy jak poprzednio. Zamiast
/// zgadywać szerokość/wysokość z wyprzedzeniem, okno MIERZY SIĘ do realnego
/// rozmiaru `NSHostingView` (`fittingSize`) po każdej zmianie fazy/tekstu —
/// to jedyny sposób, żeby karta z przyciskiem kopiowania i wieloliniowym
/// tekstem nigdy nie była ani za ciasna (obcięta treść), ani za luźna (dziura).
final class PillWindowController: NSObject {
    let model: PillViewModel
    private let panel: PillPanel
    private let hosting: NSHostingView<PillView>
    private var cancellables: Set<AnyCancellable> = []

    private let bottomMargin: CGFloat = 28
    private let defaults: UserDefaults

    /// Środek okna, do którego wraca po każdej zmianie rozmiaru (fazy). `nil`
    /// dopóki użytkownik nigdy nie przeciągnął pilla — wtedy liczymy domyślną
    /// pozycję (wyśrodkowany, przy dolnej krawędzi) jak dotychczas.
    private var userCenter: CGPoint?
    /// Odróżnia przesunięcie okna PRZEZ NAS (`resize(to:)`) od realnego
    /// przeciągnięcia myszą przez użytkownika — inaczej każda zmiana fazy
    /// zostałaby błędnie zapisana jako "nowa pozycja użytkownika".
    private var isProgrammaticMove = false

    /// Rozmiar zależy WYŁĄCZNIE od fazy, NIGDY od długości tekstu w danej
    /// chwili. Wcześniejsza wersja mierzyła się do treści przy KAŻDEJ zmianie
    /// `liveText` (czyli przy każdym słowie z ASR) — okno skakało kilka razy
    /// na sekundę. Teraz tekst rośnie i zawija się PŁYNNIE wewnątrz stałej
    /// ramki (SwiftUI samo animuje layout tekstu), a okno zmienia rozmiar
    /// tylko przy przejściu między fazami — realnie rzadko, nie co słowo.
    private static func targetSize(for phase: PillPhase) -> NSSize {
        switch phase {
        case .idle:
            NSSize(width: 220, height: 56)
        case .arming, .finalizing:
            NSSize(width: 240, height: 56)
        case .listening:
            NSSize(width: 260, height: 60)
        case .transcribing:
            // Dość miejsca na 3 zawinięte linie (§14pt) przy stałej szerokości —
            // to jest ta "sama wielkość na mówienie", nie rośnie ze zdaniem.
            NSSize(width: 460, height: 128)
        case .result:
            // Wcześniej 460x210 — zbyt duże, "aż tak wielkie okno" (feedback
            // Wojtka). Ta sama szerokość co `.transcribing`, wysokość ledwo
            // większa (miejsce na przycisk Kopiuj pod tekstem, nie osobna
            // sekcja) — długi tekst dostaje scroll W ŚRODKU tej ramki
            // (PillView.swift, maxHeight tam MUSI się zgadzać z tym rozmiarem).
            NSSize(width: 460, height: 150)
        case .error:
            NSSize(width: 340, height: 64)
        }
    }

    init(model: PillViewModel = PillViewModel(), defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        let initialRect = NSRect(origin: .zero, size: Self.targetSize(for: model.phase))
        panel = PillPanel(contentRect: initialRect)
        hosting = NSHostingView(rootView: PillView(model: model))
        hosting.frame = initialRect
        panel.contentView = hosting

        if defaults.object(forKey: SettingsKeys.pillPositionX) != nil,
           defaults.object(forKey: SettingsKeys.pillPositionY) != nil {
            userCenter = CGPoint(
                x: defaults.double(forKey: SettingsKeys.pillPositionX),
                y: defaults.double(forKey: SettingsKeys.pillPositionY)
            )
        }

        super.init()

        model.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.resize(to: Self.targetSize(for: phase))
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove), name: NSWindow.didMoveNotification, object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidMove() {
        guard !isProgrammaticMove else { return }
        // Przeciągnięcie przez użytkownika — zapamiętaj ŚRODEK i zapisz trwale.
        let frame = panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        userCenter = center
        defaults.set(Double(center.x), forKey: SettingsKeys.pillPositionX)
        defaults.set(Double(center.y), forKey: SettingsKeys.pillPositionY)
    }

    func show() {
        resize(to: Self.targetSize(for: model.phase), animated: false)
        panel.orderFrontRegardless() // NIGDY makeKeyAndOrderFront — to by aktywowało panel
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Ekran z aktywnym oknem — najlepsze przybliżenie bez czytania listy
    /// okien innych aplikacji: ekran zawierający kursor myszy, bo tam
    /// zazwyczaj jest uwaga użytkownika, z fallbackiem na ekran główny.
    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    private func resize(to size: NSSize, animated: Bool = true) {
        guard let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        let width = min(size.width, visible.width * 0.7)

        let x: CGFloat
        let y: CGFloat
        if let userCenter, visible.insetBy(dx: -40, dy: -40).contains(userCenter) {
            // Użytkownik gdzieś przeciągnął pilla — trzymaj TEN SAM środek przy
            // każdej zmianie rozmiaru (fazy), zamiast wracać do domyślnej pozycji.
            x = userCenter.x - width / 2
            y = userCenter.y - size.height / 2
        } else {
            // Domyślna pozycja (nigdy nie przeciągane, albo stary punkt spoza
            // aktualnych ekranów po zmianie konfiguracji monitorów).
            x = visible.midX - width / 2
            y = visible.minY + bottomMargin
        }
        let frame = NSRect(x: x, y: y, width: width, height: size.height)

        isProgrammaticMove = true

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && panel.isVisible && !reduceMotion {
            // `isProgrammaticMove` MUSI zostać true przez CAŁĄ animację, nie
            // tylko do momentu wywołania tej funkcji — `didMoveNotification`
            // leci dla każdej klatki pośredniej, nie tylko na końcu. Reset
            // dopiero w completion handlerze animacji, inaczej klatki pośrednie
            // zostałyby błędnie zapisane jako "użytkownik przeciągnął".
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                hosting.animator().frame = NSRect(origin: .zero, size: frame.size)
            } completionHandler: { [weak self] in
                self?.isProgrammaticMove = false
            }
        } else {
            panel.setFrame(frame, display: true)
            hosting.frame = NSRect(origin: .zero, size: frame.size)
            isProgrammaticMove = false
        }
    }
}
