import XCTest
@testable import VoiceFlow

/// §5a planu remote-mic-relay — `RemoteMicClient` wysyła `currentFocusDescription()`
/// jako ramkę tekstowa przez WS. Testy tutaj weryfikują TYLKO że rozszerzenie
/// nie crashuje i respektuje ten sam guard `AXIsProcessTrusted()` co reszta
/// `FocusProbe` (`isFocusedElementTextField`) — realną wartość tytułu okna
/// widać dopiero z nadanym uprawnieniem Dostępności, którego środowisko
/// testowe XCTest nie ma (patrz `currentFocus()` istniejące testy pośrednio
/// przez `SessionControllerCancelTests`/`WhisperSpeechEngineTests` — ten sam wzorzec).
final class FocusProbeDescriptionTests: XCTestCase {
    func testCurrentFocusDescriptionDoesNotCrashWithoutAccessibility() {
        let probe = FocusProbe()
        let description = probe.currentFocusDescription()

        if !AXIsProcessTrusted() {
            XCTAssertNil(description.windowTitle, "bez Dostępności tytuł okna musi być bezpiecznym fallbackiem nil")
        }
    }

    func testCurrentFocusDescriptionIsStableAcrossRepeatedCalls() {
        let probe = FocusProbe()
        let first = probe.currentFocusDescription()
        let second = probe.currentFocusDescription()

        // Frontmost app nie powinna zmienić się między dwoma wywołaniami w tym
        // samym momencie testu — sanity check, że metoda jest bezstanowa i
        // deterministyczna dla tego samego stanu systemu.
        XCTAssertEqual(first, second)
    }
}
