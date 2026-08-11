import SwiftUI

/// Tokeny wizualne 1:1 z `~/Programo/voiceflow/site/pl/index.html` `:root{}`
/// (NIE z `site/DESIGN.md`, który jest nieaktualny — patrz
/// docs/plans/ios-voiceflow-app.md §0). Monochromatyczne, zero koloru akcentu.
enum VFColor {
    static let background = Color(hex: 0x0B0B0C)
    static let surfaceSolid = Color(hex: 0x16_1618)
    static let surface = Color(hex: 0x16_1618).opacity(0.72)
    static let text = Color(hex: 0xF5_F5F7)
    static let muted = Color(hex: 0x9A_9AA2)
    static let faint = Color(hex: 0x55_555C)
    static let border = Color(hex: 0x28_282C)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Rodziny fontów zabundlowanych jako `.ttf` (Google Fonts, licencja OFL) i
/// zarejestrowanych przez `Info.plist` `UIAppFonts` w OBU targetach (kontener
/// i rozszerzenie klawiatury mają osobne bundle, więc każdy rejestruje własne
/// kopie plików — patrz `VoiceFlowApp/Resources/Fonts` i
/// `VoiceFlowKeyboard/Resources/Fonts`).
enum VFFont {
    /// Nagłówki — WERSALIKI, tight tracking, jak `.hero h1`/`.chapter h2` na stronie.
    static func display(_ size: CGFloat, weight: DisplayWeight = .bold) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    /// Treść — jak `.sans` na stronie.
    static func body(_ size: CGFloat, weight: BodyWeight = .regular) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    /// Status/kod/mono — jak `.mono` na stronie (`#type-line`, `.term`, statusy klawiatury).
    static func mono(_ size: CGFloat) -> Font {
        .custom("JetBrainsMono-Regular", size: size)
    }

    enum DisplayWeight {
        case medium, semibold, bold, extrabold

        var postScriptName: String {
            switch self {
            case .medium: return "Archivo-Medium"
            case .semibold: return "Archivo-SemiBold"
            case .bold: return "Archivo-Bold"
            case .extrabold: return "Archivo-ExtraBold"
            }
        }
    }

    enum BodyWeight {
        case regular, medium, semibold

        var postScriptName: String {
            switch self {
            case .regular: return "Inter-Regular"
            case .medium: return "Inter-Medium"
            case .semibold: return "Inter-SemiBold"
            }
        }
    }
}

/// Styl przycisku obrysowego z `.btn` / `.btn:hover` (bg=text, text=bg w
/// trakcie naciśnięcia — "odwrócenie" zamiast koloru akcentu).
struct VFOutlineButtonStyle: ButtonStyle {
    var solid: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let inverted = solid != configuration.isPressed
        return configuration.label
            .font(VFFont.body(15, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(inverted ? VFColor.text : Color.clear)
            .foregroundStyle(inverted ? VFColor.background : VFColor.text)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(inverted ? VFColor.text : VFColor.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    func vfEyebrow() -> some View {
        self
            .font(VFFont.body(11, weight: .semibold))
            .tracking(2.2)
            .textCase(.uppercase)
            .foregroundStyle(VFColor.muted)
    }
}

/// Wordmark: te same 5 pionowych pasków co `<svg viewBox="28 28 72 72">` w
/// `pl/index.html` (nav `.wordmark svg`) — NIE nowy rysunek, przeniesiona
/// geometria (patrz też `scratch/generate_icon.swift` użyty do AppIcon).
struct VFWordmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 72.0
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (32 - 28, 52 - 28, 8, 24),
            (46 - 28, 42 - 28, 8, 44),
            (60 - 28, 32 - 28, 8, 64),
            (74 - 28, 42 - 28, 8, 44),
            (88 - 28, 52 - 28, 8, 24),
        ]
        var path = Path()
        for (x, y, w, h) in bars {
            let r = CGRect(x: rect.minX + x * scale, y: rect.minY + y * scale, width: w * scale, height: h * scale)
            path.addRoundedRect(in: r, cornerSize: CGSize(width: 4 * scale, height: 4 * scale))
        }
        return path
    }
}

struct VFWordmark: View {
    var size: CGFloat = 30
    var body: some View {
        VFWordmarkShape()
            .fill(VFColor.text)
            .frame(width: size, height: size)
    }
}
