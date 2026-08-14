import XCTest

/// Strzałki pilota. Cała wartość tego ekranu leży w tym, że „w prawo" zawsze
/// znaczy to samo okno — dlatego kolejność ma test, a nie tylko komentarz.
final class TerminalOrderTests: XCTestCase {

    private func window(_ id: String, x: Int, y: Int, terminal: Bool = true, focused: Bool = false) -> WireWindow {
        WireWindow(
            id: id, app: terminal ? "Terminal" : "Safari", title: "okno \(id)",
            x: x, y: y, w: 800, h: 600, z: 0, focused: focused,
            kind: terminal ? .terminal : .other
        )
    }

    /// Kolejność ekranowa (góra→dół, lewo→prawo), NIE kolejność nakładania:
    /// `z` zmienia się przy każdym podniesieniu okna, więc pilot sortujący po
    /// `z` przestawiałby sobie listę pod palcem.
    func testKolejnoscIdziePoPozycjiNaBiurku() {
        let windows = [
            window("c", x: 0, y: 900),
            window("b", x: 1000, y: 0),
            window("a", x: 0, y: 0),
            window("safari", x: 500, y: 500, terminal: false),
        ]
        XCTAssertEqual(TerminalOrder.sorted(windows).map(\.id), ["a", "b", "c"])
    }

    func testStrzalkaZawijaSieNaKoncach() {
        let windows = [window("a", x: 0, y: 0), window("b", x: 1000, y: 0), window("c", x: 0, y: 900)]
        XCTAssertEqual(TerminalOrder.step(from: "a", in: windows, offset: 1)?.id, "b")
        XCTAssertEqual(TerminalOrder.step(from: "c", in: windows, offset: 1)?.id, "a")
        XCTAssertEqual(TerminalOrder.step(from: "a", in: windows, offset: -1)?.id, "c")
    }

    /// Bez zaznaczenia zaczepiamy się o okno, które Mac zgłasza jako aktywne —
    /// inaczej pierwsza strzałka po wejściu w pilota skacze na początek listy
    /// zamiast obok tego, na co właśnie patrzysz.
    func testBezZaznaczeniaZaczepiamySieOAktywneOkno() {
        let windows = [
            window("a", x: 0, y: 0),
            window("b", x: 1000, y: 0, focused: true),
            window("c", x: 0, y: 900),
        ]
        XCTAssertEqual(TerminalOrder.step(from: nil, in: windows, offset: 1)?.id, "c")
        XCTAssertEqual(TerminalOrder.step(from: nil, in: windows, offset: -1)?.id, "a")
    }

    func testBrakPunktuZaczepieniaBierzeSkrajneOkno() {
        let windows = [window("a", x: 0, y: 0), window("b", x: 1000, y: 0)]
        XCTAssertEqual(TerminalOrder.step(from: "zniknelo", in: windows, offset: 1)?.id, "a")
        XCTAssertEqual(TerminalOrder.step(from: "zniknelo", in: windows, offset: -1)?.id, "b")
    }

    func testBrakTerminaliNieWywracaPilota() {
        XCTAssertNil(TerminalOrder.step(from: nil, in: [], offset: 1))
        XCTAssertNil(TerminalOrder.step(from: "a", in: [window("s", x: 0, y: 0, terminal: false)], offset: 1))
    }
}
