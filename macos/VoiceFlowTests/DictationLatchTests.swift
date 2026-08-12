import XCTest
@testable import VoiceFlow

/// Zatrzask dyktowania — cała maszyna stanów na sterowanym czasie, bez
/// prawdziwej klawiatury i bez czekania.
final class DictationLatchTests: XCTestCase {

    func testZwykleTrzymanieDzialaJakZawsze() {
        let latch = DictationLatch()
        XCTAssertEqual(latch.pressed(at: 0), .begin)
        XCTAssertEqual(latch.released(at: 1.2), .end)
        XCTAssertFalse(latch.isLatched)
    }

    func testPodwojneStuknieciePozostawiaSesjeOtwartaAKolejneKonczy() {
        let latch = DictationLatch()
        // Tap 1: krótka sesja begin+end — dokładnie jak dotąd przy szybkim tapie.
        XCTAssertEqual(latch.pressed(at: 0), .begin)
        XCTAssertEqual(latch.released(at: 0.1), .end)
        // Tap 2 w oknie podwójnego stuknięcia: begin, a puszczenie NIE kończy.
        XCTAssertEqual(latch.pressed(at: 0.3), .begin)
        XCTAssertEqual(latch.released(at: 0.4), .none)
        XCTAssertTrue(latch.isLatched)
        // Tap 3 (dowolnie później): wciśnięcie kończy, puszczenie milczy.
        XCTAssertEqual(latch.pressed(at: 9.0), .end)
        XCTAssertEqual(latch.released(at: 9.1), .none)
        XCTAssertFalse(latch.isLatched)
        // Po zamknięciu zatrzasku wszystko wraca do normy.
        XCTAssertEqual(latch.pressed(at: 12.0), .begin)
        XCTAssertEqual(latch.released(at: 13.5), .end)
    }

    func testPojedynczeStukniecaDalekoOdSiebieNieZatrzaskuja() {
        let latch = DictationLatch()
        XCTAssertEqual(latch.pressed(at: 0), .begin)
        XCTAssertEqual(latch.released(at: 0.1), .end)
        // Drugie stuknięcie po 2 s — za późno na podwójne.
        XCTAssertEqual(latch.pressed(at: 2.0), .begin)
        XCTAssertEqual(latch.released(at: 2.1), .end)
        XCTAssertFalse(latch.isLatched)
    }

    func testDlugieTrzymanieMiedzyStuknieciamiZerujePamiec() {
        let latch = DictationLatch()
        XCTAssertEqual(latch.pressed(at: 0), .begin)
        XCTAssertEqual(latch.released(at: 0.1), .end)
        // Hold dłuższy niż próg stuknięcia — nie jest częścią podwójnego tapu.
        XCTAssertEqual(latch.pressed(at: 0.3), .begin)
        XCTAssertEqual(latch.released(at: 1.5), .end)
        // Szybkie stuknięcie zaraz po — wciąż pojedyncze, bo hold zerował pamięć.
        XCTAssertEqual(latch.pressed(at: 1.6), .begin)
        XCTAssertEqual(latch.released(at: 1.7), .end)
        XCTAssertFalse(latch.isLatched)
    }

    func testResetPoEscapeZwalniaZatrzask() {
        let latch = DictationLatch()
        _ = latch.pressed(at: 0)
        _ = latch.released(at: 0.1)
        _ = latch.pressed(at: 0.3)
        _ = latch.released(at: 0.4)
        XCTAssertTrue(latch.isLatched)
        latch.reset()
        XCTAssertFalse(latch.isLatched)
        // Po resecie stuknięcie normalnie ZACZYNA dyktowanie, nie „kończy".
        XCTAssertEqual(latch.pressed(at: 5.0), .begin)
    }
}

extension DictationLatch.Action: Equatable {}
