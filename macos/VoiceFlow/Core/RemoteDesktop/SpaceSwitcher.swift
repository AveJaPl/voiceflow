import AppKit
import CoreGraphics

/// Przełączanie pulpitów (Spaces) dla pilota.
///
/// DLACZEGO NIE SKRÓT KLAWISZOWY. Pierwsza wersja wysyłała ⌃←/⌃→ przez
/// `CGEvent`, tak jak wszystkie pozostałe klawisze pilota. Zmierzone na żywo
/// 2026-08-14 na Macu Wojtka (skrypt `spacetest.swift`, trzy warianty:
/// same flagi / osobne zdarzenie modyfikatora / trzy różne miejsca wstrzyknięcia
/// zdarzenia — `cghidEventTap`, `cgSessionEventTap`, `cgAnnotatedSessionEventTap`):
/// **żaden nie przełączył pulpitu**, mimo że proces miał zgodę Dostępności, a
/// skróty Mission Control (79/81) były włączone, i mimo że na ekranie głównym
/// były trzy pulpity. WindowServer po prostu nie honoruje syntetycznych zdarzeń
/// dla przełączania pulpitów. Dlatego ⌘V działało, a „PULPIT ◀ ▶" nie robiło
/// absolutnie nic.
///
/// Działa za to prywatne API CoreGraphics (`CGSManagedDisplaySetCurrentSpace`),
/// to samo, którego używają narzędzia typu Spaceman — zmierzone w tym samym
/// przebiegu: `err=0` i pulpit faktycznie się zmienił. To jest API prywatne,
/// więc traktujemy je jak coś, co może zniknąć w kolejnym macOS: każde
/// wywołanie jest osłonięte, brak zmiany pulpitu zwraca `false`, a wołający ma
/// wtedy zapasową ścieżkę (skrót klawiszowy) i komunikat dla użytkownika.
enum SpaceSwitcher {

    /// Zmiana o `offset` pulpitów na ekranie, na który patrzysz (tym z kursorem;
    /// bez kursora — głównym). BEZ zawijania: skrajny pulpit zwraca `false`,
    /// dokładnie jak przesunięcie palcami po gładziku, które na końcu po prostu
    /// nic nie robi.
    @discardableResult
    static func step(_ offset: Int) -> Bool {
        guard offset != 0 else { return false }
        let connection = CGSDefaultConnection()
        guard let display = displayUnderPointer(connection: connection) ?? managedDisplays(connection: connection).first else {
            return false
        }
        guard let current = display.currentSpace,
              let index = display.spaces.firstIndex(of: current) else { return false }
        let target = index + offset
        guard display.spaces.indices.contains(target) else { return false }
        let result = CGSManagedDisplaySetCurrentSpace(connection, display.identifier as CFString, display.spaces[target])
        return result == 0
    }

    /// Ile pulpitów ma ekran, na który patrzysz, i który jest aktywny —
    /// do pokazania na telefonie („pulpit 2/3").
    static func currentPosition() -> (index: Int, count: Int)? {
        let connection = CGSDefaultConnection()
        guard let display = displayUnderPointer(connection: connection) ?? managedDisplays(connection: connection).first,
              let current = display.currentSpace,
              let index = display.spaces.firstIndex(of: current) else { return nil }
        return (index + 1, display.spaces.count)
    }

    // MARK: - Odczyt układu pulpitów

    private struct Display {
        let identifier: String
        let spaces: [UInt64]
        let currentSpace: UInt64?
        let frame: CGRect?
    }

    private static func managedDisplays(connection: Int32) -> [Display] {
        guard let raw = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let identifier = entry["Display Identifier"] as? String else { return nil }
            let spaces = (entry["Spaces"] as? [[String: Any]])?.compactMap { $0["ManagedSpaceID"] as? UInt64 } ?? []
            let current = (entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64
            return Display(
                identifier: identifier,
                spaces: spaces,
                currentSpace: current,
                frame: screenFrame(forDisplayIdentifier: identifier)
            )
        }
    }

    /// Ekran z kursorem — najlepsze przybliżenie „ekranu, na który patrzysz",
    /// to samo, którym posługuje się pill (`PillWindowController.targetScreen`).
    private static func displayUnderPointer(connection: Int32) -> Display? {
        let mouse = NSEvent.mouseLocation
        let displays = managedDisplays(connection: connection)
        return displays.first { $0.frame?.contains(mouse) == true }
    }

    /// Ramka ekranu o danym UUID. `NSScreen` nie oddaje UUID wprost, więc
    /// idziemy przez `CGDirectDisplayID` → UUID.
    private static func screenFrame(forDisplayIdentifier identifier: String) -> CGRect? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { continue }
            let string = CFUUIDCreateString(nil, uuid) as String
            if string == identifier { return screen.frame }
            // Ekran główny bywa raportowany jako „Main" zamiast UUID.
            if identifier == "Main", screen == NSScreen.screens.first { return screen.frame }
        }
        return nil
    }
}

// MARK: - Prywatne API CoreGraphics

@_silgen_name("_CGSDefaultConnection")
private func CGSDefaultConnection() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ connection: Int32, _ display: CFString, _ space: UInt64) -> Int32
