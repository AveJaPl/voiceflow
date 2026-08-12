import Foundation

/// Mózg strony Maca dla zdalnego sterowania z telefonu — tłumaczy `PhoneFrame`
/// (kontrakt `shared/wire/ControlFrames.swift`) na operacje systemowe i
/// odpowiedzi `MacFrame`.
///
/// CAŁA logika protokołu jest tutaj, a WSZYSTKIE efekty uboczne (AX, AppleScript,
/// zrzuty, dyktowanie, sieć) wchodzą przez `Dependencies` — dzięki temu testy
/// jednostkowe przechodzą pełne scenariusze (start ze starą generacją, porażka
/// fokusu, zajęta sesja) bez jednego prawdziwego okna, dokładnie te same, które
/// telefon przechodził przeciw makiecie `tools/macsim`.
///
/// Zasada nadrzędna (plan §4.5): telefon dostaje `started` DOPIERO po
/// zweryfikowanym podniesieniu celu. Każda ścieżka porażki wysyła `error` z
/// kodem z kontraktu — cisza jest najgorszą możliwą odpowiedzią, bo telefon
/// czeka z pełnym prebuforem audio.
@MainActor
final class RemoteControlHub {

    struct Dependencies {
        /// Świeża migawka okien (podbija generację).
        var snapshotWindows: () -> WindowsFrame
        /// Okno z OSTATNIEJ migawki, o ile generacja się zgadza.
        var windowFor: (_ id: String, _ generation: Int) -> WireWindow?
        /// Podnieś okno i zweryfikuj fokus. `true` = cel na froncie.
        var focusWindow: (_ window: WireWindow) async -> Bool
        /// Przesuń/zmień rozmiar. `true` = AX przyjął.
        var moveWindow: (_ window: WireWindow, _ frame: MoveFrame) -> Bool
        /// Ogon treści terminala; `nil` = podgląd niedostępny dla tego okna.
        var terminalLines: (_ window: WireWindow) -> [String]?
        /// Zrzut ekranu; `nil` = brak uprawnienia albo błąd przechwycenia.
        var screenshot: () async -> (header: ScreenshotHeader, data: Data)?
        /// Zacznij dyktowanie. `false` = sesja zajęta (lokalny skrót w trakcie).
        var beginDictation: () -> Bool
        var endDictation: () -> Void
        var cancelDictation: () -> Void
        /// Wyślij skrót klawiszowy do aplikacji na froncie. `false` = akord
        /// spoza słownika tej wersji Maca.
        var postKey: (_ chord: KeyChord) -> Bool
        var sendFrame: (_ frame: MacFrame) -> Void
        var sendBinary: (_ data: Data) -> Void
        var macName: String
        var capabilities: MacCaps
    }

    private let deps: Dependencies
    /// Cel bieżącej ZDALNEJ wypowiedzi — do ramek `started`/`injected`.
    private(set) var activeTarget: WireWindow?
    /// Subskrypcja podglądu terminala: id okna + generacja + licznik ramek.
    private var terminalSubscription: (id: String, generation: Int)?
    private var terminalSeq = 0
    private var terminalTimer: Timer?

    init(deps: Dependencies) {
        self.deps = deps
    }

    deinit {
        terminalTimer?.invalidate()
    }

    /// Telefon się połączył (jego `hello` doszło) — przedstawiamy się.
    func sendHello() {
        deps.sendFrame(.hello(MacHello(mac: deps.macName, caps: deps.capabilities)))
    }

    func handle(_ frame: PhoneFrame) async {
        switch frame {
        case .hello:
            sendHello()

        case .requestWindows:
            deps.sendFrame(.windows(deps.snapshotWindows()))

        case .requestScreenshot:
            guard let (header, data) = await deps.screenshot() else {
                deps.sendFrame(.error(ErrorFrame(code: .notPermitted, message: "Brak uprawnienia Nagrywanie ekranu")))
                return
            }
            deps.sendFrame(.screenshot(header))
            deps.sendBinary(data)

        case .subscribe(let subscription):
            if subscription.windows {
                deps.sendFrame(.windows(deps.snapshotWindows()))
            }
            if let terminalID = subscription.terminal {
                startTerminalStream(id: terminalID)
            } else {
                stopTerminalStream()
            }

        case .unsubscribe:
            stopTerminalStream()

        case .focusWindow(let id, let generation):
            guard let window = deps.windowFor(id, generation) else {
                deps.sendFrame(.error(ErrorFrame(code: .windowGone, target: id)))
                return
            }
            let focused = await deps.focusWindow(window)
            if !focused {
                deps.sendFrame(.error(ErrorFrame(code: .focusFailed, target: id)))
            }
            deps.sendFrame(.windows(deps.snapshotWindows()))

        case .moveWindow(let move):
            guard let window = deps.windowFor(move.id, move.generation) else {
                deps.sendFrame(.error(ErrorFrame(code: .windowGone, target: move.id)))
                return
            }
            guard deps.moveWindow(window, move) else {
                deps.sendFrame(.error(ErrorFrame(code: .unsupported, target: move.id)))
                return
            }
            deps.sendFrame(.windows(deps.snapshotWindows()))

        case .start(let target, let generation):
            await handleStart(target: target, generation: generation)

        case .end:
            deps.endDictation()

        case .cancel:
            activeTarget = nil
            deps.cancelDictation()

        case .key(let chord):
            if !deps.postKey(chord) {
                deps.sendFrame(.error(ErrorFrame(code: .unsupported, message: "Nieznany akord: \(chord.rawValue)")))
            }
        }
    }

    /// Atomowy start (plan §4.5): walidacja migawki → podniesienie → weryfikacja
    /// → dopiero `started`. Telefon do tego czasu trzyma audio w prebuforze.
    private func handleStart(target: String?, generation: Int?) async {
        guard deps.beginDictation() else {
            deps.sendFrame(.error(ErrorFrame(code: .busy, target: target)))
            return
        }

        guard let target else {
            // Stare zachowanie (`RemoteMicClient` sprzed tego zadania):
            // dyktuj do tego, co na froncie. Zgodność wsteczna z kontraktu.
            activeTarget = nil
            deps.sendFrame(.started(target: nil))
            return
        }

        guard let window = deps.windowFor(target, generation ?? -1) else {
            deps.cancelDictation()
            deps.sendFrame(.error(ErrorFrame(code: .windowGone, target: target)))
            return
        }
        let focused = await deps.focusWindow(window)
        guard focused else {
            deps.cancelDictation()
            deps.sendFrame(.error(ErrorFrame(code: .focusFailed, target: target)))
            return
        }
        activeTarget = window
        deps.sendFrame(.started(target: target))
    }

    /// Wołane przez właściciela (RemoteMicClient), gdy pipeline dyktowania
    /// zakończył wypowiedź i tekst wylądował w oknie.
    func dictationFinished(text: String, injected: Bool) {
        defer { activeTarget = nil }
        guard let activeTarget else { return }
        if injected {
            deps.sendFrame(.injected(InjectedFrame(target: activeTarget.id, text: text, via: activeTarget.inject)))
        } else {
            deps.sendFrame(.error(ErrorFrame(
                code: .focusFailed, message: "Tekst nie trafił do okna — uratowany",
                target: activeTarget.id, text: text
            )))
        }
    }

    // MARK: - Strumień terminala

    private func startTerminalStream(id: String) {
        // Świeża migawka wiąże subskrypcję z bieżącą generacją.
        let snapshot = deps.snapshotWindows()
        terminalSubscription = (id, snapshot.generation)
        terminalSeq = 0
        pushTerminalFrame()
        terminalTimer?.invalidate()
        terminalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pushTerminalFrame() }
        }
    }

    private func stopTerminalStream() {
        terminalTimer?.invalidate()
        terminalTimer = nil
        terminalSubscription = nil
    }

    private func pushTerminalFrame() {
        guard let subscription = terminalSubscription,
              let window = deps.windowFor(subscription.id, subscription.generation) else { return }
        guard let lines = deps.terminalLines(window) else {
            // Okno przestało być czytelne (zgoda cofnięta, karta zamknięta) —
            // kończymy strumień zamiast słać puste ramki co sekundę.
            stopTerminalStream()
            deps.sendFrame(.error(ErrorFrame(code: .unsupported, target: subscription.id)))
            return
        }
        terminalSeq += 1
        deps.sendFrame(.terminal(TerminalFrame(
            id: subscription.id, generation: subscription.generation,
            seq: terminalSeq, lines: lines
        )))
    }
}
