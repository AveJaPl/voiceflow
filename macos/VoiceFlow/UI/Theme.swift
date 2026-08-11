import SwiftUI

/// Tokeny wizualne przeniesione **wprost z aplikacji linuksowej**
/// (`app/voiceflow_app/style.py`), bo to ona jest wzorcem wyglądu dla
/// wszystkich platform (decyzja Filipa 2026-08-11: „bazujmy wszystko na tym,
/// jak wygląda to na Linuksie").
///
/// Wartości są skopiowane, nie dobrane na oko — dopóki tak zostanie, trzy
/// aplikacje da się utrzymać w jednym wyglądzie bez porównywania zrzutów
/// ekranu. Zmiana palety zaczyna się w `style.py` i schodzi tutaj.
///
/// Paleta jest monochromatyczna z jednym wyjątkiem: `recording` to jedyny
/// kolor w całym interfejsie i niesie jedno znaczenie — trwa nagrywanie.
enum VF {

    // MARK: - Kolory (1:1 z CSS w style.py)

    enum Color {
        /// Tło okna — `#0d0d0f`.
        static let background = SwiftUI.Color(vfHex: 0x0D0D0F)
        /// Karta/sekcja — `#131316`.
        static let surface = SwiftUI.Color(vfHex: 0x131316)
        /// Element wyżej w hierarchii (pole, hover) — `#1b1b1e`.
        static let surfaceRaised = SwiftUI.Color(vfHex: 0x1B1B1E)
        /// Obrys kart i pól — `#232327`.
        static let border = SwiftUI.Color(vfHex: 0x232327)
        /// Delikatny obrys na tle karty — `rgba(255,255,255,0.07)`.
        static let hairline = SwiftUI.Color.white.opacity(0.07)

        /// Tekst podstawowy — `#f5f5f7`.
        static let text = SwiftUI.Color(vfHex: 0xF5F5F7)
        /// Tekst drugorzędny — `rgba(255,255,255,0.55)`.
        static let muted = SwiftUI.Color.white.opacity(0.55)
        /// Podpisy i etykiety sekcji — `rgba(255,255,255,0.35)`.
        static let faint = SwiftUI.Color.white.opacity(0.35)

        /// Jedyny kolor w interfejsie: nagrywanie trwa — `#ff453a`.
        static let recording = SwiftUI.Color(vfHex: 0xFF453A)
    }

    // MARK: - Siatka odstępów (SPACING_GRID ze style.py)

    enum Space {
        static let x4: CGFloat = 4
        static let x8: CGFloat = 8
        static let x12: CGFloat = 12
        static let x16: CGFloat = 16
        static let x20: CGFloat = 20
        static let x24: CGFloat = 24
        static let x32: CGFloat = 32
        static let x48: CGFloat = 48
    }

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let pill: CGFloat = 16
    }

    // MARK: - Typografia

    /// Systemowa, nie zabundlowana. Wersja iOS ładuje Archivo/Inter przez
    /// `UIAppFonts`; tutaj tego nie ma, a `.custom` z brakującą rodziną cicho
    /// spada do fontu systemowego — czyli dawałoby ten sam efekt, tylko bez
    /// możliwości sprawdzenia, czy zadziałało. Deklarujemy to wprost.
    enum Font {
        static func display(_ size: CGFloat) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .default)
        }
        static func body(_ size: CGFloat = 13) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .default)
        }
        static func label(_ size: CGFloat = 11) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .default)
        }
        static func mono(_ size: CGFloat = 12) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .monospaced)
        }
    }

    // MARK: - Ruch (MOTION_MS / REVEAL_MS ze style.py)

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
        static let reveal = Animation.easeOut(duration: 0.20)
    }
}

extension SwiftUI.Color {
    /// Inicjalizator z literału szesnastkowego, taki sam jak w `ios/Shared/Theme.swift`.
    init(vfHex hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {
    /// Karta w stylu linuksowym: ciemna powierzchnia, włosowy obrys, zaokrąglenie.
    func vfCard(padding: CGFloat = VF.Space.x16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: VF.Radius.card, style: .continuous)
                    .fill(VF.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VF.Radius.card, style: .continuous)
                    .strokeBorder(VF.Color.hairline, lineWidth: 1)
            )
    }

    /// Etykieta sekcji — WERSALIKI, rozstrzelone, przygaszone; jak
    /// `.section-label` w aplikacji linuksowej.
    func vfSectionLabel() -> some View {
        self
            .font(VF.Font.label(10))
            .tracking(0.8)
            .foregroundStyle(VF.Color.faint)
            .textCase(.uppercase)
    }
}
