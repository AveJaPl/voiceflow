import XCTest
@testable import VoiceFlow

private final class FakeDucking: AudioDucking {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

private final class FakeDiscordMute: DiscordMuteToggling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

/// Fejkowy scheduler: NIE czeka na prawdziwy zegar — test decyduje kiedy
/// "minie" próg, wołając `fire()`, albo anuluje jak prawdziwe `beginUtterance`.
private final class FakeSchedule: CancellableSchedule {
    private(set) var cancelled = false
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func cancel() { cancelled = true }
    func fire() {
        guard !cancelled else { return }
        action()
    }
}

final class DictationDuckingTests: XCTestCase {
    private func makeSUT() -> (DictationDucking, FakeDucking, FakeDiscordMute, () -> FakeSchedule?) {
        let ducker = FakeDucking()
        let mute = FakeDiscordMute()
        var lastSchedule: FakeSchedule?
        let sut = DictationDucking(
            ducker: ducker,
            discordMute: mute,
            gapThreshold: 1.5,
            schedule: { _, action in
                let schedule = FakeSchedule(action: action)
                lastSchedule = schedule
                return schedule
            }
        )
        return (sut, ducker, mute, { lastSchedule })
    }

    func testFirstBeginStartsDuckingAndMute() {
        let (sut, ducker, mute, _) = makeSUT()
        sut.begin()
        XCTAssertEqual(ducker.startCount, 1)
        XCTAssertEqual(mute.startCount, 1)
    }

    func testContinuationDoesNotStartTwice() {
        // Kolejne beginUtterance PRZED upływem progu (endUtterance jeszcze nie
        // "wystrzelił" restore) — to kontynuacja tej samej myśli.
        let (sut, ducker, mute, lastSchedule) = makeSUT()
        sut.begin()
        sut.end()
        XCTAssertNotNil(lastSchedule(), "endUtterance musi zaplanować odroczone przywrócenie")

        sut.begin() // kontynuacja — anuluje odroczone przywrócenie

        XCTAssertEqual(ducker.startCount, 1, "drugie wejście w tej samej myśli nie powinno przyciszać drugi raz")
        XCTAssertEqual(mute.startCount, 1)
        XCTAssertTrue(lastSchedule()?.cancelled ?? false, "kontynuacja musi anulować odroczone przywrócenie")
    }

    func testRealEndRestoresAfterThresholdFires() {
        // endUtterance, a próg MIJA bez kolejnego beginUtterance — prawdziwy koniec.
        let (sut, ducker, mute, lastSchedule) = makeSUT()
        sut.begin()
        sut.end()
        lastSchedule()?.fire()

        XCTAssertEqual(ducker.stopCount, 1)
        XCTAssertEqual(mute.stopCount, 1)
    }

    func testSecondUtteranceAfterRealEndStartsAgain() {
        let (sut, ducker, mute, lastSchedule) = makeSUT()
        sut.begin()
        sut.end()
        lastSchedule()?.fire() // prawdziwy koniec, przywrócono

        sut.begin() // nowa, niezależna sesja

        XCTAssertEqual(ducker.startCount, 2)
        XCTAssertEqual(mute.startCount, 2)
    }
}
