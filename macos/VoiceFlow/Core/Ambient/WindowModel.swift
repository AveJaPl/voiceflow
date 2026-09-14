import Foundation

/// Model okien pulpitu dla trybu nasłuchu (`AmbientListener` → `TerminalRegistry`).
///
/// Do 2026-09-14 te typy żyły w `shared/wire/ControlFrames.swift` jako
/// kontrakt sieciowy z telefonem (zdalne sterowanie pulpitem). Zdalne
/// sterowanie wycięto razem z zakładką „Mac” w apce iOS; zostały czyste
/// struktury, bo `WindowSnapshotter` i `TerminalRegistry` liczą na nich
/// nazwy kodowe terminali. Nazwy `Wire*` celowo zachowane — mniej diffu,
/// zero zmiany semantyki.
struct WindowKind: RawRepresentable, Equatable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let terminal = WindowKind(rawValue: "terminal")
    static let other = WindowKind(rawValue: "other")
}

struct InjectMode: RawRepresentable, Equatable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let clipboard = InjectMode(rawValue: "clipboard")
    static let liveTyping = InjectMode(rawValue: "liveTyping")
}

struct WireDisplay: Equatable, Identifiable {
    let id: Int
    let w: Int
    let h: Int
    let main: Bool
}

struct WireWindow: Equatable, Identifiable {
    let id: String
    let app: String
    let bundleID: String?
    let title: String?
    let display: Int
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    /// Kolejność nakładania: 0 = najwyżej. Pochodzi z `CGWindowList`, bo AX go nie zna.
    let z: Int
    let focused: Bool
    let minimized: Bool
    let kind: WindowKind
    let inject: InjectMode

    init(
        id: String, app: String, bundleID: String? = nil, title: String? = nil,
        display: Int = 1, x: Int, y: Int, w: Int, h: Int, z: Int = 0,
        focused: Bool = false, minimized: Bool = false,
        kind: WindowKind = .other, inject: InjectMode = .clipboard
    ) {
        self.id = id; self.app = app; self.bundleID = bundleID; self.title = title
        self.display = display; self.x = x; self.y = y; self.w = w; self.h = h; self.z = z
        self.focused = focused; self.minimized = minimized; self.kind = kind; self.inject = inject
    }

    /// Tytuł do pokazania człowiekowi. Okno bez tytułu (zdarza się) nie może
    /// wyglądać jak pusty wiersz.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return app
    }

    var isTerminal: Bool { kind == .terminal }
}

struct WindowsFrame: Equatable {
    let generation: Int
    let displays: [WireDisplay]
    let windows: [WireWindow]
}
