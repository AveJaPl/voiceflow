import AppKit
import CoreGraphics

/// Drabina wstrzykiwania z §7 planu: AX → CGEvent unicode → schowek+⌘V.
/// Tu implementujemy poziom 2 (domyślny dla live typingu, `apply(_:)`) i
/// poziom 3 (`insertViaClipboard`, fallback dla pól poza AX i dla dużych bloków).
/// Poziom 1 (AXValue/AXSelectedText) świadomie pominięty w MVP — CGEvent unicode
/// działa wszędzie, w tym w Electronie, i to jest jedyna ścieżka, którą trzeba
/// utrzymać na starcie.
final class TextInjector: TextInjecting {
    enum InjectorError: Error {
        case cgEventCreationFailed
    }

    private static let backspaceKeyCode: CGKeyCode = 0x33
    private static let vKeyCode: CGKeyCode = 0x09
    /// `CGEvent.keyboardSetUnicodeString` ma niedokumentowany, ale sprawdzony
    /// w praktyce limit długości bufora na jedno wywołanie — tniemy na kawałki.
    private static let unicodeChunkSize = 20

    /// Kasuje `deleteCount` znaków wstecz (backspace), potem wpisuje `insert`
    /// znak po znaku przez CGEvent unicode. Używane przy live typingu.
    func apply(_ plan: InjectionPlan) throws {
        if plan.deleteCount > 0 {
            try sendBackspaces(count: plan.deleteCount)
        }
        if !plan.insert.isEmpty {
            try sendUnicodeString(plan.insert)
        }
    }

    /// Fallback dla pól poza zasięgiem AX/CGEvent (§7 pkt 3): kopiuje `text` do
    /// schowka, wkleja ⌘V, po chwili przywraca poprzednią zawartość schowka.
    func insertViaClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.first?.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try sendCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    // MARK: - CGEvent

    private func sendBackspaces(count: Int) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKeyCode, keyDown: false)
            else { throw InjectorError.cgEventCreationFailed }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func sendUnicodeString(_ text: String) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        var offset = 0
        while offset < utf16.count {
            let end = min(offset + Self.unicodeChunkSize, utf16.count)
            let chunk = Array(utf16[offset..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw InjectorError.cgEventCreationFailed }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            offset = end
        }
    }

    private func sendCommandV() throws {
        do {
            try CGEventKeyCombo.post(keyCode: Self.vKeyCode, flags: .maskCommand)
        } catch {
            throw InjectorError.cgEventCreationFailed
        }
    }
}
