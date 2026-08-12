import AppKit
import ApplicationServices

/// Podnosi wskazane okno na front i WERYFIKUJE, że się udało — atomowy start
/// dyktowania z planu §4.5: „lepiej nie wstawić, niż wstawić w złe okno".
/// Telefon dostaje `started` DOPIERO po pozytywnej weryfikacji; do tego czasu
/// audio zostaje w prebuforze telefonu.
@MainActor
enum WindowFocuser {

    /// Podnosi okno o numerze CGWindowID należące do `pid` i czeka (do
    /// `timeout`), aż aplikacja faktycznie jest z przodu. Zwraca `false` bez
    /// żadnego efektu ubocznego poza próbą podniesienia.
    ///
    /// Mapowanie CGWindowID → element AX: AX nie zna numerów CGWindowList, ale
    /// prywatny-ale-stabilny `_AXUIElementGetWindow` (używany przez każdy
    /// menedżer okien: Rectangle, yabai, AeroSpace) zwraca CGWindowID dla
    /// elementu AX. Idziemy po `AXWindows` procesu i porównujemy numery.
    static func focus(windowID: CGWindowID, pid: pid_t, timeout: TimeInterval = 0.5) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }

        if let axWindow = axWindow(for: windowID, pid: pid) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        app.activate()

        // Weryfikacja: krótkie odpytywanie zamiast jednego sleepa — zwykle
        // fokus przechodzi w 1-2 iteracjach, pełne 500 ms płacimy tylko przy
        // porażce.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Przesuwa/zmienia rozmiar okna przez AX. Zwraca `false` gdy okna nie ma
    /// albo AX odmówił (np. okno pełnoekranowe).
    static func move(windowID: CGWindowID, pid: pid_t, to frame: CGRect) -> Bool {
        guard let axWindow = axWindow(for: windowID, pid: pid) else { return false }
        var origin = frame.origin
        var size = CGSize(width: frame.width, height: frame.height)
        guard let originValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let originOK = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, originValue)
        let sizeOK = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        return originOK == .success && sizeOK == .success
    }

    private static func axWindow(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }
        for axWindow in axWindows {
            var number: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &number) == .success, number == windowID {
                return axWindow
            }
        }
        return nil
    }
}

/// Prywatne, ale stabilne od dekady API ApplicationServices — jedyna droga
/// z elementu AX do CGWindowID. Deklaracja własna, bo nagłówki go nie eksponują.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
