import XCTest

/// Tytuły są DOSŁOWNIE z Maca Wojtka (odczyt 2026-08-14), bo tylko one mówią,
/// co naprawdę przychodzi na drucie.
final class TerminalTitleTests: XCTestCase {

    func testZostajeSamaNazwaSesji() {
        XCTAssertEqual(
            TerminalTitle.short("wojciechplonka — ✳ Estalo CRM aplikacja - przegląd błędów i ulepszenia — node ◂ claude --dangerously-skip-permissions — 130×88"),
            "Estalo CRM aplikacja - przegląd błędów i ulepszenia"
        )
        XCTAssertEqual(
            TerminalTitle.short("wojciechplonka — ⠐ Test Common Crawl for Polish business pages with NIP — caffeinate ◂ claude --dangerously-skip-permissions — 181×47"),
            "Test Common Crawl for Polish business pages with NIP"
        )
    }

    func testBrakTytuluToBrakNazwy() {
        XCTAssertNil(TerminalTitle.short(nil))
        XCTAssertNil(TerminalTitle.short(""))
    }

    /// Zwykły tytuł bez ozdób ma zostać nietknięty.
    func testProstyTytulPrzechodziBezZmian() {
        XCTAssertEqual(TerminalTitle.short("bash — 80×24"), "bash")
    }
}
