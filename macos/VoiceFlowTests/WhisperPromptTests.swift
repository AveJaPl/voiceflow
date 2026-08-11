import XCTest
@testable import VoiceFlow

/// Testy dla `WhisperSpeechEngine.buildInitialPrompt` — czysta funkcja, bez
/// ładowania modelu whisper.cpp. §Zadanie 1 audytu: słownik użytkownika z
/// Ustawień dochodzi do `initial_prompt` JAKO PIERWSZA część, NIE zastępując
/// istniejącego zszywania kontekstu (`stitchContext` — ostatnie skomitowane
/// słowa tej sesji, patrz `WhisperSpeechEngine.decodeStepIfNeeded`).
final class WhisperPromptTests: XCTestCase {

    func testPustyPromptGdyBrakSlownikaIKontekstu() {
        XCTAssertEqual(WhisperSpeechEngine.buildInitialPrompt(vocabulary: [], stitchContext: ""), "")
    }

    func testSamSlownikBezZszywanegoKontekstu() {
        let prompt = WhisperSpeechEngine.buildInitialPrompt(vocabulary: ["Programo", "Estalo"], stitchContext: "")
        XCTAssertEqual(prompt, "Słownictwo: Programo, Estalo.")
    }

    func testSamKontekstZszywaniaBezSlownika() {
        let prompt = WhisperSpeechEngine.buildInitialPrompt(vocabulary: [], stitchContext: "ostatnie skomitowane słowa")
        XCTAssertEqual(prompt, "ostatnie skomitowane słowa")
    }

    func testSlownikIKontekstZszywaniaLACZASIENieZastepujaSie() {
        let prompt = WhisperSpeechEngine.buildInitialPrompt(vocabulary: ["Programo"], stitchContext: "ostatnie słowa")
        XCTAssertEqual(prompt, "Słownictwo: Programo. ostatnie słowa")
    }

    func testPusteWpisySlownikaSaIgnorowane() {
        let prompt = WhisperSpeechEngine.buildInitialPrompt(vocabulary: ["", "  ", "Baulx"], stitchContext: "")
        XCTAssertEqual(prompt, "Słownictwo: Baulx.")
    }
}
