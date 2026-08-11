import XCTest
@testable import VoiceFlow

/// Testy dla `Formatter.mergedDictionary` — słownik/słowa własne z Ustawień
/// (§Zadanie 1 audytu). Druga warstwa korekty (Apple-engine), niezależna od
/// promptu whisper.cpp (`WhisperSpeechEngineTests.testBuildInitialPrompt...`).
final class FormatterTests: XCTestCase {

    func testMergedDictionaryDodajeSlowaUzytkownikaDoDomyslnych() {
        let merged = Formatter.mergedDictionary(userVocabulary: ["Baulx"], base: ["programo": "Programo"])
        XCTAssertEqual(merged["programo"], "Programo", "domyślny wpis musi zostać")
        XCTAssertEqual(merged["baulx"], "Baulx", "słowo użytkownika musi dojść")
    }

    func testMergedDictionaryUzytkownikNadpisujeDomyslny() {
        // Użytkownik wpisał "PROGRAMO" (inna forma niż domyślny wpis) — jego
        // wersja MUSI wygrać, nie domyślna.
        let merged = Formatter.mergedDictionary(userVocabulary: ["PROGRAMO"], base: ["programo": "Programo"])
        XCTAssertEqual(merged["programo"], "PROGRAMO")
    }

    func testMergedDictionaryIgnorujePusteWpisy() {
        // Puste wiersze zostają w UI w trakcie edycji (nowo dodany, jeszcze
        // niewypełniony wiersz) — nie mogą trafić do słownika jako klucz "".
        let merged = Formatter.mergedDictionary(userVocabulary: ["", "  ", "Baulx"], base: [:])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["baulx"], "Baulx")
    }

    func testMergedDictionaryIgnorujeFrazyWieloczlonowe() {
        // `applyDictionary` dopasowuje słowo po słowie — fraza wieloczłonowa
        // nigdy nie trafi w pojedynczy klucz, więc nie ma sensu jej dodawać.
        let merged = Formatter.mergedDictionary(userVocabulary: ["Wojciech Płonka"], base: [:])
        XCTAssertTrue(merged.isEmpty)
    }

    func testFormatUzywaSlownikaZeSlowamiUzytkownika() {
        let merged = Formatter.mergedDictionary(userVocabulary: ["Estalo"], base: Formatter.defaultDictionary)
        let formatter = Formatter(dictionary: merged)
        let result = formatter.format("mówię o estalo dzisiaj", isSentenceStart: true, endsUtterance: true)
        XCTAssertTrue(result.contains("Estalo"), "słowo użytkownika powinno zostać poprawione: \(result)")
    }
}
