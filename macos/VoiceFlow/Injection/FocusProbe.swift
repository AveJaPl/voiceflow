import AppKit
import ApplicationServices

/// Sprawdza przez Accessibility, czy sfokusowany element w aktywnej aplikacji
/// jest polem tekstowym — od tego zależy tryb wstawiania (§7 planu, "Reguła
/// Wojtka: tekst ma zawsze trafić do aktywnego okna, tam gdzie stoi kursor").
enum InjectionMode: Equatable {
    /// AX potwierdza pole tekstowe — CGEvent unicode znak po znaku, bez schowka.
    case liveTyping
    /// AX nie potwierdza (albo aplikacja jest na liście wyjątków) — tekst czeka
    /// w pillu, wstawiamy na końcu przez schowek + ⌘V.
    case clipboardFallback
}

struct FocusInfo {
    let frontmostBundleID: String?
    let mode: InjectionMode
}

/// Nazwa aplikacji + tytuł okna na froncie (§5a planu remote-mic-relay) — do
/// podglądu na telefonie, żeby Wojtek widział, do jakiego okna trafi tekst
/// PRZED puszczeniem przycisku, zamiast dyktować w ciemno. Osobna od
/// `FocusInfo` wyżej: tamta liczy TYLKO tryb wstrzykiwania (live/schowek),
/// ta opisuje CO jest na froncie, dla kogoś kto nie widzi ekranu Maca.
struct FocusDescription: Equatable {
    let appName: String?
    let windowTitle: String?
}

final class FocusProbe {
    /// Bundle id, dla których wymuszamy tryb schowka mimo że AX widzi pole
    /// tekstowe — live typing gryzie się tam z autouzupełnianiem / auto-wcięciami
    /// (§7: IDE, terminale).
    static let clipboardOnlyBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.jetbrains.intellij",
        // Aplikacje na Electronie — realnie zaobserwowane 2026-08-09: dyktowanie
        // do Claude Desktop kończyło się "nie wkleja się", mimo że dokładnie ten
        // sam mechanizm (self-test) działał bez zarzutu w TextEdicie. Zamiast
        // ryzykować kolejny raz na żywej aplikacji, te aplikacje dostają
        // najbezpieczniejszą ścieżkę (wklej na końcu), tak jak IDE wyżej.
        "com.anthropic.claudefordesktop",
        "com.tinyspeck.slackmacgap", // Slack
        "com.hnc.Discord",
        "notion.id", // Notion
    ]

    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    func currentFocus() -> FocusInfo {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let bundleID, Self.clipboardOnlyBundleIDs.contains(bundleID) {
            return FocusInfo(frontmostBundleID: bundleID, mode: .clipboardFallback)
        }

        guard isFocusedElementTextField() else {
            return FocusInfo(frontmostBundleID: bundleID, mode: .clipboardFallback)
        }
        return FocusInfo(frontmostBundleID: bundleID, mode: .liveTyping)
    }

    /// §5a planu remote-mic-relay — `RemoteMicClient` wysyła to przez WS jako
    /// ramkę tekstową przy zmianie focusu i na żądanie telefonu. Bez
    /// uprawnienia Dostępności `windowTitle` jest zawsze `nil` (ten sam guard
    /// co `isFocusedElementTextField` niżej) — bezpieczny fallback, telefon
    /// wtedy pokaże samą nazwę aplikacji.
    func currentFocusDescription() -> FocusDescription {
        let app = NSWorkspace.shared.frontmostApplication
        let windowTitle = app.flatMap(Self.frontmostWindowTitle(for:))
        return FocusDescription(appName: app?.localizedName, windowTitle: windowTitle)
    }

    private static func frontmostWindowTitle(for app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard windowResult == .success, let windowRef else { return nil }
        // swiftlint:disable:next force_cast
        let window = windowRef as! AXUIElement

        var titleRef: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard titleResult == .success, let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    /// Trzeba mieć nadane uprawnienie Dostępności (AXIsProcessTrusted), inaczej
    /// zawsze zwraca false i wołający dostaje bezpieczny fallback do schowka.
    private func isFocusedElementTextField() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef
        )
        guard focusResult == .success, let focusedElementRef else { return false }
        // swiftlint:disable:next force_cast
        let focusedElement = focusedElementRef as! AXUIElement

        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            focusedElement, kAXRoleAttribute as CFString, &roleRef
        )
        guard roleResult == .success, let role = roleRef as? String else { return false }

        if Self.textRoles.contains(role) {
            return true
        }

        // Niektóre pola webowe (Electron/Chromium) raportują generyczną rolę,
        // ale mają AXValue typu String i AXEditable — sprawdź to jako drugi trop.
        var editableRef: CFTypeRef?
        let editableResult = AXUIElementCopyAttributeValue(
            focusedElement, "AXEditable" as CFString, &editableRef
        )
        if editableResult == .success, let editable = editableRef as? Bool, editable {
            return true
        }

        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            focusedElement, kAXValueAttribute as CFString, &valueRef
        )
        return valueResult == .success && valueRef is String
    }
}
