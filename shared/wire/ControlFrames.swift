import Foundation

/// Kontrakt ramek WebSocket między telefonem a Makiem — JEDNO źródło prawdy dla
/// obu platform. Ten plik jest dołączany przez `sources:` w `ios/project.yml`
/// ORAZ w `macos/project.yml`; nie wolno go kopiować, bo kopia rozjeżdża się po
/// cichu, a rozjazd kontraktu objawia się dopiero na żywym urządzeniu (telefon
/// milczy, Mac nie reaguje, nic nie loguje błędu).
/// Pełny opis: `docs/plans/2026-08-11-ios-zdalne-sterowanie-mac.md` §4.
///
/// ZALEŻNOŚCI: wyłącznie Foundation. Żadnego UIKit/AppKit/SwiftUI — inaczej
/// przestanie się kompilować po jednej ze stron.
///
/// PODZIAŁ RAMEK (§4.1):
/// - tekstowe        — JSON sterujący, w obie strony (ten plik),
/// - binarne phone→mac — WYŁĄCZNIE PCM Int16 LE, mono, 16 kHz,
/// - binarne mac→phone — WYŁĄCZNIE bajty obrazu, ZAWSZE bezpośrednio po ramce
///   `screenshot`, która je opisuje (WebSocket gwarantuje kolejność).
///
/// ZGODNOŚĆ W PRZÓD: każdy typ wyliczeniowy przenoszony po sieci
/// (`WireErrorCode`, `WindowKind`, `InjectMode`, `KeyChord`) jest strukturą
/// `RawRepresentable`, a nie `enum` — dekoduje DOWOLNY string zamiast rzucać
/// wyjątkiem. Nieznany typ ramki dekoduje się do `.unknown(type:)`. Starsza
/// apka nie może się wywrócić o nowszego Maca; to nie jest ostrożność na wyrost,
/// tylko warunek tego, żeby dało się wydać obie strony niezależnie.
enum Wire {
    /// Wersja kontraktu. Podbijamy przy KAŻDEJ zmianie łamiącej zgodność.
    static let protocolVersion = 1

    /// Format audio na drucie — musi się zgadzać z `RemoteMicClient.wireFormat`
    /// po stronie macOS (Int16 LE, mono, 16 kHz).
    static let audioSampleRate: Double = 16_000
    static let audioChannels: UInt32 = 1
}

// MARK: - Typy przenoszone po sieci (tolerancyjne na nieznane wartości)

/// Kod błędu. `mac_offline` pochodzi z RELAYA, nie z Maca (`relay/src/relayHub.js`)
/// — apka musi go obsłużyć tak samo jak błędy Maca, inaczej „Mac wyłączony"
/// objawia się jako cisza.
struct WireErrorCode: RawRepresentable, Codable, Equatable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    /// Okno zniknęło albo migawka jest nieaktualna (`generation` się nie zgadza).
    static let windowGone = WireErrorCode(rawValue: "windowGone")
    /// Nie udało się przenieść celu na front — NIC nie zostało wstrzyknięte.
    static let focusFailed = WireErrorCode(rawValue: "focusFailed")
    /// Mac jest w trakcie innej wypowiedzi (np. lokalny skrót).
    static let busy = WireErrorCode(rawValue: "busy")
    /// Brak uprawnienia systemowego (Dostępność / Nagrywanie ekranu / Automatyzacja).
    static let notPermitted = WireErrorCode(rawValue: "notPermitted")
    /// Operacja niemożliwa dla tego okna (np. przesunięcie okna pełnoekranowego).
    static let unsupported = WireErrorCode(rawValue: "unsupported")
    static let timeout = WireErrorCode(rawValue: "timeout")
    /// Z relaya: druga strona nie jest podłączona.
    static let macOffline = WireErrorCode(rawValue: "mac_offline")
}

/// Rodzaj okna. `terminal` jest wyróżniony, bo TYLKO dla niego istnieje warstwa 3
/// (podgląd treści jako tekst) — patrz plan §3.2.
struct WindowKind: RawRepresentable, Codable, Equatable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let terminal = WindowKind(rawValue: "terminal")
    static let other = WindowKind(rawValue: "other")
}

/// Tryb wstawiania wyliczony przez `FocusProbe` po stronie Maca. Telefon go NIE
/// wybiera — tylko pokazuje, bo dla terminali i Electronów jedyną działającą
/// drogą jest schowek + ⌘V.
struct InjectMode: RawRepresentable, Codable, Equatable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let clipboard = InjectMode(rawValue: "clipboard")
    static let liveTyping = InjectMode(rawValue: "liveTyping")
}

/// Skrót klawiszowy wysyłany do celu. Zamknięty słownik zamiast dowolnego
/// „naciśnij co ci powiem": zdalne naciskanie dowolnych klawiszy na cudzym Macu
/// to nie jest funkcja, której ktokolwiek tu potrzebuje (plan §4.6).
struct KeyChord: RawRepresentable, Codable, Equatable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    /// Zatwierdzenie promptu — bez tego tekst zostaje w linii i nic się nie dzieje.
    static let return_ = KeyChord(rawValue: "return")
    static let escape = KeyChord(rawValue: "escape")
    static let cmdReturn = KeyChord(rawValue: "cmdReturn")
    /// Przerwanie tego, co biegnie w terminalu.
    static let ctrlC = KeyChord(rawValue: "ctrlC")
    /// Cofnięcie w edytorze / aplikacji okienkowej.
    static let cmdZ = KeyChord(rawValue: "cmdZ")
    /// Wklejenie schowka Maca — pilot nie przesyła treści, tylko naciska klawisz.
    static let cmdV = KeyChord(rawValue: "cmdV")
    /// „Cofnij" w powłoce: ⌘Z w terminalu nie robi nic, a wyczyszczenie linii
    /// jest tym, czego się w tym miejscu naprawdę chce (skasowanie promptu,
    /// który przed chwilą wpadł z dyktowania).
    static let ctrlU = KeyChord(rawValue: "ctrlU")
    /// Przeskok na sąsiedni pulpit (Mission Control) — klawiaturowy odpowiednik
    /// przesunięcia trzema palcami po gładziku. Wysyłane ZAWSZE bez celu:
    /// podnoszenie okna przed zmianą pulpitu przeniosłoby nas z powrotem na ten
    /// pulpit, na którym to okno stoi, czyli dokładnie odwrotnie do zamiaru.
    static let ctrlLeft = KeyChord(rawValue: "ctrlLeft")
    static let ctrlRight = KeyChord(rawValue: "ctrlRight")
}

// MARK: - Ładunki

struct MacCaps: Codable, Equatable {
    let screenshot: Bool
    let terminalText: Bool
    let move: Bool

    init(screenshot: Bool, terminalText: Bool, move: Bool) {
        self.screenshot = screenshot
        self.terminalText = terminalText
        self.move = move
    }

    /// Brakująca zdolność = wyłączona. Mac starszy niż telefon nie może przez
    /// pominięcie pola przypadkiem obiecać czegoś, czego nie umie.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenshot = c.wireValue(.screenshot, default: false)
        terminalText = c.wireValue(.terminalText, default: false)
        move = c.wireValue(.move, default: false)
    }
}

struct MacHello: Codable, Equatable {
    let `protocol`: Int
    let mac: String
    let caps: MacCaps

    init(protocol proto: Int = Wire.protocolVersion, mac: String, caps: MacCaps) {
        self.protocol = proto
        self.mac = mac
        self.caps = caps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = c.wireValue(.protocol, default: 0)
        mac = c.wireValue(.mac, default: "Mac")
        caps = c.wireValue(.caps, default: MacCaps(screenshot: false, terminalText: false, move: false))
    }
}

struct PhoneHello: Codable, Equatable {
    let `protocol`: Int
    let device: String

    init(protocol proto: Int = Wire.protocolVersion, device: String) {
        self.protocol = proto
        self.device = device
    }
}

struct WireDisplay: Codable, Equatable, Identifiable {
    let id: Int
    let w: Int
    let h: Int
    let main: Bool

    init(id: Int, w: Int, h: Int, main: Bool) {
        self.id = id; self.w = w; self.h = h; self.main = main
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.wireValue(.id, default: 0)
        w = c.wireValue(.w, default: 0)
        h = c.wireValue(.h, default: 0)
        main = c.wireValue(.main, default: false)
    }
}

/// Jedno okno w migawce. `id` jest ważny WYŁĄCZNIE w obrębie swojej `generation`
/// (plan §5, landmina 5) — dlatego każda komenda telefonu niesie obie wartości.
struct WireWindow: Codable, Equatable, Identifiable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.wireValue(.id, default: "")
        app = c.wireValue(.app, default: "")
        bundleID = try? c.decodeIfPresent(String.self, forKey: .bundleID)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        display = c.wireValue(.display, default: 1)
        x = c.wireValue(.x, default: 0)
        y = c.wireValue(.y, default: 0)
        w = c.wireValue(.w, default: 0)
        h = c.wireValue(.h, default: 0)
        z = c.wireValue(.z, default: 0)
        focused = c.wireValue(.focused, default: false)
        minimized = c.wireValue(.minimized, default: false)
        kind = c.wireValue(.kind, default: .other)
        inject = c.wireValue(.inject, default: .clipboard)
    }

    /// Tytuł do pokazania człowiekowi. Okno bez tytułu (zdarza się) nie może
    /// wyglądać na telefonie jak pusty wiersz.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return app
    }

    var isTerminal: Bool { kind == .terminal }
}

struct WindowsFrame: Codable, Equatable {
    let generation: Int
    let displays: [WireDisplay]
    let windows: [WireWindow]

    init(generation: Int, displays: [WireDisplay], windows: [WireWindow]) {
        self.generation = generation; self.displays = displays; self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = c.wireValue(.generation, default: 0)
        displays = c.wireValue(.displays, default: [])
        windows = c.wireValue(.windows, default: [])
    }
}

/// Nagłówek zrzutu — bajty JPEG przychodzą JAKO NASTĘPNA ramka binarna (§4.1).
struct ScreenshotHeader: Codable, Equatable {
    let generation: Int
    let format: String
    let w: Int
    let h: Int
    let bytes: Int

    init(generation: Int, format: String = "jpeg", w: Int, h: Int, bytes: Int) {
        self.generation = generation; self.format = format; self.w = w; self.h = h; self.bytes = bytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = c.wireValue(.generation, default: 0)
        format = c.wireValue(.format, default: "jpeg")
        w = c.wireValue(.w, default: 0)
        h = c.wireValue(.h, default: 0)
        bytes = c.wireValue(.bytes, default: 0)
    }
}

/// Warstwa 3: treść terminala jako TEKST (plan §3.2). `seq` rośnie o 1 przy każdej
/// wysyłce dla danego okna — telefon odrzuca ramki spóźnione po zmianie celu.
struct TerminalFrame: Codable, Equatable {
    let id: String
    let generation: Int
    let seq: Int
    let lines: [String]

    init(id: String, generation: Int, seq: Int, lines: [String]) {
        self.id = id; self.generation = generation; self.seq = seq; self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.wireValue(.id, default: "")
        generation = c.wireValue(.generation, default: 0)
        seq = c.wireValue(.seq, default: 0)
        lines = c.wireValue(.lines, default: [])
    }
}

/// Istnieje w kodzie macOS OD DZIŚ (`RemoteMicClient.sendFocus`) — nie zmieniamy
/// jej kształtu, żeby nowy telefon działał ze starszym Makiem.
struct FocusFrame: Codable, Equatable {
    let app: String?
    let window: String?

    init(app: String?, window: String?) { self.app = app; self.window = window }
}

struct InjectedFrame: Codable, Equatable {
    let target: String?
    let text: String
    let via: InjectMode

    init(target: String?, text: String, via: InjectMode) {
        self.target = target; self.text = text; self.via = via
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try? c.decodeIfPresent(String.self, forKey: .target)
        text = c.wireValue(.text, default: "")
        via = c.wireValue(.via, default: .clipboard)
    }
}

struct ErrorFrame: Codable, Equatable {
    let code: WireErrorCode
    let message: String?
    let target: String?
    /// Tekst uratowany, gdy wstrzyknięcie się nie powiodło (plan §4.5) — żeby
    /// wypowiedź nie przepadła tylko dlatego, że focus uciekł.
    let text: String?

    init(code: WireErrorCode, message: String? = nil, target: String? = nil, text: String? = nil) {
        self.code = code; self.message = message; self.target = target; self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.wireValue(.code, default: WireErrorCode(rawValue: "unknown"))
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        target = try? c.decodeIfPresent(String.self, forKey: .target)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
    }
}

struct SubscribeFrame: Codable, Equatable {
    let windows: Bool
    let screenshot: Bool
    /// Identyfikator okna terminala, którego treść ma płynąć; `nil` = żadnego.
    let terminal: String?

    init(windows: Bool, screenshot: Bool, terminal: String?) {
        self.windows = windows; self.screenshot = screenshot; self.terminal = terminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = c.wireValue(.windows, default: false)
        screenshot = c.wireValue(.screenshot, default: false)
        terminal = try? c.decodeIfPresent(String.self, forKey: .terminal)
    }
}

struct MoveFrame: Codable, Equatable {
    let id: String
    let generation: Int
    let x: Int
    let y: Int
    let w: Int
    let h: Int

    init(id: String, generation: Int, x: Int, y: Int, w: Int, h: Int) {
        self.id = id; self.generation = generation
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

// MARK: - Ramki Mac → telefon

enum MacFrame: Equatable {
    case hello(MacHello)
    case windows(WindowsFrame)
    /// Po tej ramce przychodzi DOKŁADNIE jedna ramka binarna z bajtami obrazu.
    case screenshot(ScreenshotHeader)
    case terminal(TerminalFrame)
    case focus(FocusFrame)
    /// Mikrofon otwarty — DOPIERO TERAZ telefon wypycha bufor i strumieniuje (§4.5).
    case started(target: String?)
    case preview(text: String)
    case injected(InjectedFrame)
    case error(ErrorFrame)
    /// Typ, którego ta wersja apki nie zna. Ignorujemy, nie wywracamy się.
    case unknown(type: String)

    var type: String {
        switch self {
        case .hello: "hello"
        case .windows: "windows"
        case .screenshot: "screenshot"
        case .terminal: "terminal"
        case .focus: "focus"
        case .started: "started"
        case .preview: "preview"
        case .injected: "injected"
        case .error: "error"
        case .unknown(let t): t
        }
    }
}

extension MacFrame: Codable {
    private enum K: String, CodingKey { case type, target, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "hello": self = .hello(try MacHello(from: decoder))
        case "windows": self = .windows(try WindowsFrame(from: decoder))
        case "screenshot": self = .screenshot(try ScreenshotHeader(from: decoder))
        case "terminal": self = .terminal(try TerminalFrame(from: decoder))
        case "focus": self = .focus(try FocusFrame(from: decoder))
        case "started": self = .started(target: try? c.decodeIfPresent(String.self, forKey: .target))
        case "preview": self = .preview(text: (try? c.decode(String.self, forKey: .text)) ?? "")
        case "injected": self = .injected(try InjectedFrame(from: decoder))
        case "error": self = .error(try ErrorFrame(from: decoder))
        default: self = .unknown(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .hello(let p): try p.encode(to: encoder)
        case .windows(let p): try p.encode(to: encoder)
        case .screenshot(let p): try p.encode(to: encoder)
        case .terminal(let p): try p.encode(to: encoder)
        case .focus(let p): try p.encode(to: encoder)
        case .started(let target): try c.encodeIfPresent(target, forKey: .target)
        case .preview(let text): try c.encode(text, forKey: .text)
        case .injected(let p): try p.encode(to: encoder)
        case .error(let p): try p.encode(to: encoder)
        case .unknown: break
        }
    }
}

// MARK: - Ramki telefon → Mac

enum PhoneFrame: Equatable {
    case hello(PhoneHello)
    /// Telefon deklaruje, czego chce TERAZ. Bez subskrypcji Mac nie wysyła nic
    /// poza odpowiedziami na komendy — to jest cały mechanizm oszczędzania
    /// baterii i transferu (plan §3.3).
    case subscribe(SubscribeFrame)
    case unsubscribe
    case requestWindows
    case requestScreenshot
    case focusWindow(id: String, generation: Int)
    case moveWindow(MoveFrame)
    /// `target == nil` zachowuje STARE zachowanie („dyktuj do tego, co na froncie"),
    /// którego dziś używa `RemoteMicClient` — zgodność wsteczna.
    case start(target: String?, generation: Int?)
    case end
    case cancel
    /// Naciśnięcie klawisza na Macu. `target` = okno, które ma być przedtem
    /// podniesione i zweryfikowane — bez tego klawisz leci do CZEGOKOLWIEK, co
    /// akurat jest na froncie, a to przy pilocie w telefonie jest loteria.
    /// `nil` zachowuje stare zachowanie („naciśnij na froncie") i zgodność ze
    /// starszym telefonem.
    case key(chord: KeyChord, target: String?, generation: Int?)

    var type: String {
        switch self {
        case .hello: "hello"
        case .subscribe: "subscribe"
        case .unsubscribe: "unsubscribe"
        case .requestWindows: "requestWindows"
        case .requestScreenshot: "requestScreenshot"
        case .focusWindow: "focusWindow"
        case .moveWindow: "moveWindow"
        case .start: "start"
        case .end: "end"
        case .cancel: "cancel"
        case .key: "key"
        }
    }
}

extension PhoneFrame: Codable {
    private enum K: String, CodingKey { case type, id, generation, target, chord }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "hello": self = .hello(try PhoneHello(from: decoder))
        case "subscribe": self = .subscribe(try SubscribeFrame(from: decoder))
        case "unsubscribe": self = .unsubscribe
        case "requestWindows": self = .requestWindows
        case "requestScreenshot": self = .requestScreenshot
        case "focusWindow":
            self = .focusWindow(
                id: (try? c.decode(String.self, forKey: .id)) ?? "",
                generation: (try? c.decode(Int.self, forKey: .generation)) ?? 0
            )
        case "moveWindow": self = .moveWindow(try MoveFrame(from: decoder))
        case "start":
            self = .start(
                target: try? c.decodeIfPresent(String.self, forKey: .target),
                generation: try? c.decodeIfPresent(Int.self, forKey: .generation)
            )
        case "end": self = .end
        case "cancel": self = .cancel
        case "key":
            self = .key(
                chord: (try? c.decode(KeyChord.self, forKey: .chord)) ?? .return_,
                target: try? c.decodeIfPresent(String.self, forKey: .target),
                generation: try? c.decodeIfPresent(Int.self, forKey: .generation)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: K.type, in: c, debugDescription: "Nieznany typ ramki telefonu: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .hello(let p): try p.encode(to: encoder)
        case .subscribe(let p): try p.encode(to: encoder)
        case .moveWindow(let p): try p.encode(to: encoder)
        case .focusWindow(let id, let generation):
            try c.encode(id, forKey: .id)
            try c.encode(generation, forKey: .generation)
        case .start(let target, let generation):
            try c.encodeIfPresent(target, forKey: .target)
            try c.encodeIfPresent(generation, forKey: .generation)
        case .key(let chord, let target, let generation):
            try c.encode(chord, forKey: .chord)
            try c.encodeIfPresent(target, forKey: .target)
            try c.encodeIfPresent(generation, forKey: .generation)
        case .unsubscribe, .requestWindows, .requestScreenshot, .end, .cancel: break
        }
    }
}

// MARK: - Kodek

/// Jedyne wejście i wyjście dla ramek tekstowych. Dekodowanie ramek OD Maca
/// nigdy nie rzuca — nieznane i uszkodzone ramki wracają jako `.unknown`,
/// bo pojedyncza dziwna ramka nie może zrywać sesji dyktowania.
enum WireCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()

    static func encodeToString(_ frame: PhoneFrame) throws -> String {
        String(decoding: try encoder.encode(frame), as: UTF8.self)
    }

    static func encodeToString(_ frame: MacFrame) throws -> String {
        String(decoding: try encoder.encode(frame), as: UTF8.self)
    }

    static func decodeMacFrame(_ text: String) -> MacFrame {
        guard let data = text.data(using: .utf8),
              let frame = try? decoder.decode(MacFrame.self, from: data) else {
            return .unknown(type: "")
        }
        return frame
    }

    static func decodePhoneFrame(_ text: String) -> PhoneFrame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(PhoneFrame.self, from: data)
    }
}

// MARK: - Pomocnik dekodowania

private extension KeyedDecodingContainer {
    /// Brakujące ALBO uszkodzone pole dostaje wartość domyślną zamiast wywracać
    /// całą ramkę. Świadomy wybór: lepiej pokazać okno bez tytułu niż stracić
    /// całą listę okien przez jedno pole, którego Mac nie przysłał.
    /// `try?` spłaszcza `T??` z `decodeIfPresent` do `T?`, więc brak klucza i błąd
    /// dekodowania trafiają tu w to samo miejsce — i oba dostają wartość domyślną.
    func wireValue<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
