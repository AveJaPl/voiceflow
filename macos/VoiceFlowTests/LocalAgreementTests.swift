import XCTest
@testable import VoiceFlow

/// Testy dla `LocalAgreement` — kryterium #2 planu
/// (docs/plans/whisper-local-engine-pl.md): "okno się zgadza → commit; okno
/// się NIE zgadza → nadal volatile". Referencyjna sonda badawcza
/// (`stream_probe.c`, Etap 0e) świadomie NIE implementowała tego kroku
/// (`etap0e-wyniki.md` §6), więc te testy są jedyną weryfikacją algorytmu.
final class LocalAgreementTests: XCTestCase {

    func testPierwszeOknoZawszeVolatile() {
        // Nie ma z czym porównać — nic nie może się jeszcze "zgodzić".
        let agreement = LocalAgreement()
        let step = agreement.observe(hypothesis: "Dzień dobry")
        XCTAssertEqual(step.newlyCommitted, "")
        XCTAssertEqual(step.volatile, "Dzień dobry")
    }

    func testDwaKolejneOknaZgadzajaSieCommitujaWspolnyPrefiks() {
        let agreement = LocalAgreement()
        _ = agreement.observe(hypothesis: "Dzień dobry")
        // Drugie okno rozszerza pierwsze o kolejne słowo — wspólny prefiks
        // "Dzień dobry" jest teraz potwierdzony DWOMA kolejnymi oknami.
        let step = agreement.observe(hypothesis: "Dzień dobry chciałbym")
        XCTAssertEqual(step.newlyCommitted, "Dzień dobry")
        XCTAssertEqual(step.volatile, "chciałbym")
    }

    func testOknoKtoreSieNieZgadzaZostajeVolatile() {
        let agreement = LocalAgreement()
        _ = agreement.observe(hypothesis: "Dzień dobry")
        // Whisper "zmienił zdanie" na temat pierwszego słowa — brak wspólnego
        // prefiksu, więc NIC nie wolno jeszcze zamrozić.
        let step = agreement.observe(hypothesis: "Dziennik dobry")
        XCTAssertEqual(step.newlyCommitted, "", "Bez zgody dwóch kolejnych okien nic nie może być commitowane")
        XCTAssertEqual(step.volatile, "Dziennik dobry")
    }

    func testKolejneKrokiPoCommitachPorownujaTylkoResztke() {
        // Po pierwszym commicie `LocalAgreement` powinien porównywać kolejne
        // hipotezy do RESZTKI (nie do całości) — bo wołający (WhisperSpeechEngine)
        // od tej pory karmi go hipotezami dotyczącymi WYŁĄCZNIE nieskomitowanego
        // audio (okno przesuwa się razem z punktem commitu).
        let agreement = LocalAgreement()
        _ = agreement.observe(hypothesis: "Dzień dobry")
        let step1 = agreement.observe(hypothesis: "Dzień dobry chciałbym")
        XCTAssertEqual(step1.newlyCommitted, "Dzień dobry")
        XCTAssertEqual(step1.volatile, "chciałbym")

        // Kolejne okno dekoduje TYLKO nieskomitowane audio — jego hipoteza
        // dotyczy więc wyłącznie "chciałbym...", nie całego zdania od nowa.
        let step2 = agreement.observe(hypothesis: "chciałbym dzisiaj")
        XCTAssertEqual(step2.newlyCommitted, "chciałbym")
        XCTAssertEqual(step2.volatile, "dzisiaj")
    }

    func testResetCzysciHistorie() {
        let agreement = LocalAgreement()
        _ = agreement.observe(hypothesis: "Dzień dobry")
        agreement.reset()
        // Po resecie pierwsze okno znowu nie ma z czym się porównać.
        let step = agreement.observe(hypothesis: "Dzień dobry")
        XCTAssertEqual(step.newlyCommitted, "")
        XCTAssertEqual(step.volatile, "Dzień dobry")
    }

    func testPustaHipotezaNieCommitujeNic() {
        let agreement = LocalAgreement()
        _ = agreement.observe(hypothesis: "")
        let step = agreement.observe(hypothesis: "")
        XCTAssertEqual(step.newlyCommitted, "")
        XCTAssertEqual(step.volatile, "")
    }
}
