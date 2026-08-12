import AppKit
import CoreGraphics

/// Migawka okien pulpitu dla telefonu — `WindowsFrame` z kontraktu
/// (`shared/wire/ControlFrames.swift`), plan §3.1.
///
/// Źródłem jest `CGWindowListCopyWindowInfo`, nie AX: tylko CGWindowList zna
/// kolejność nakładania (`z`) i działa bez chodzenia po drzewie AX każdej
/// aplikacji. AX wchodzi do gry dopiero przy PODNOSZENIU okna
/// (`WindowFocuser`) i przesuwaniu — tam z kolei CGWindowList jest bezradny.
///
/// `generation` rośnie przy każdej migawce. Identyfikator okna jest ważny
/// WYŁĄCZNIE w obrębie swojej generacji (plan §5, landmina 5): telefon
/// odsyła obie wartości, a `RemoteControlHub` odrzuca komendy ze starą
/// generacją jako `windowGone`, zamiast zgadywać, czy okno o tym numerze to
/// wciąż to samo okno.
@MainActor
final class WindowSnapshotter {

    /// Aplikacje, których okna są terminalami — tylko dla nich istnieje
    /// warstwa podglądu tekstowego (plan §3.2) i tap-do-dyktowania promptów.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "org.alacritty",
    ]

    private(set) var generation = 0
    /// Ostatnia migawka — do walidacji `id`+`generation` w komendach telefonu.
    private(set) var lastSnapshot: WindowsFrame?
    /// PID właściciela okna z ostatniej migawki — kontrakt go nie niesie
    /// (telefonowi do niczego), a AX wymaga go do podniesienia/przesunięcia.
    private var pidByWindowID: [String: pid_t] = [:]

    func pid(forWindowID id: String) -> pid_t? { pidByWindowID[id] }

    func snapshot() -> WindowsFrame {
        generation += 1

        let displays = NSScreen.screens.enumerated().map { index, screen in
            WireDisplay(
                id: index + 1,
                w: Int(screen.frame.width),
                h: Int(screen.frame.height),
                main: screen == NSScreen.main
            )
        }

        // CELOWO bez `.optionOnScreenOnly`: ta opcja ogranicza listę do
        // BIEŻĄCEGO biurka (Space), a terminale Wojtka żyją na innych —
        // zaobserwowane na żywo: „połączony · 0 terminali" przy ośmiu
        // otwartych oknach Terminala. Bierzemy wszystkie okna i odsiewamy
        // sami: warstwa 0, sensowny rozmiar, nieprzezroczyste.
        let options: CGWindowListOption = [.excludeDesktopElements]
        let rawList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { info in
                // Okna z alpha 0 to niewidoczne pomocnicze powierzchnie.
                ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.1
            }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var runningApps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            runningApps[app.processIdentifier] = app
        }

        var windows: [WireWindow] = []
        pidByWindowID.removeAll(keepingCapacity: true)
        for (zIndex, info) in rawList.enumerated() {
            // Warstwa 0 = zwykłe okna. Wyższe warstwy to paski menu, Dock,
            // nakładki (w tym nasz własny pill) — śmieci z punktu widzenia
            // telefonu.
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let windowID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            // Okna mniejsze niż to są dekoracjami (cienie, uchwyty, popovery).
            guard bounds.width >= 120, bounds.height >= 80 else { continue }

            let appName = (info[kCGWindowOwnerName as String] as? String) ?? "?"
            let bundleID = runningApps[pid]?.bundleIdentifier
            let isTerminal = bundleID.map(Self.terminalBundleIDs.contains) ?? false
            pidByWindowID["\(windowID)"] = pid

            windows.append(WireWindow(
                id: "\(windowID)",
                app: appName,
                bundleID: bundleID,
                title: info[kCGWindowName as String] as? String,
                display: displayIndex(for: bounds, screens: NSScreen.screens),
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                w: Int(bounds.width),
                h: Int(bounds.height),
                z: zIndex,
                focused: pid == frontmostPID && zIndex == frontmostZIndex(of: rawList, pid: pid),
                minimized: false, // CGWindowList z .optionOnScreenOnly nie zwraca zwiniętych
                kind: isTerminal ? .terminal : .other,
                // Terminale i Electrony przyjmują tekst niezawodnie tylko przez
                // schowek+⌘V — a to i tak nasza domyślna ścieżka wstrzykiwania.
                inject: .clipboard
            ))
        }

        let frame = WindowsFrame(generation: generation, displays: displays, windows: windows)
        lastSnapshot = frame
        return frame
    }

    /// Okno z OSTATNIEJ migawki — tylko jeśli generacja się zgadza.
    func window(id: String, generation: Int) -> WireWindow? {
        guard let lastSnapshot, lastSnapshot.generation == generation else { return nil }
        return lastSnapshot.windows.first { $0.id == id }
    }

    /// Numer ekranu (1-indeksowany, jak `WireDisplay.id`), na którym leży
    /// środek okna. Okno poza wszystkimi ekranami dostaje 1 — lepsze niż
    /// znikanie z mapy.
    private func displayIndex(for bounds: CGRect, screens: [NSScreen]) -> Int {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // CGWindowList używa współrzędnych z (0,0) w LEWYM GÓRNYM rogu ekranu
        // głównego, NSScreen — w lewym dolnym. Odbijamy Y względem wysokości
        // ekranu głównego, żeby porównywać w jednym układzie.
        guard let mainScreen = NSScreen.screens.first else { return 1 }
        let flipped = CGPoint(x: center.x, y: mainScreen.frame.height - center.y)
        for (index, screen) in screens.enumerated() where screen.frame.contains(flipped) {
            return index + 1
        }
        return 1
    }

    /// Najwyższy (najmniejszy) indeks warstwy 0 należący do procesu — tylko to
    /// okno procesu na froncie jest naprawdę sfokusowane.
    private func frontmostZIndex(of rawList: [[String: Any]], pid: pid_t) -> Int {
        for (index, info) in rawList.enumerated() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            return index
        }
        return -1
    }
}
