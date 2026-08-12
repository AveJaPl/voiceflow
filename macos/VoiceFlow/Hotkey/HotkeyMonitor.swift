import CoreGraphics
import Foundation
import QuartzCore
import os.log

/// Global hold-to-talk na `CGEventTap` (§7: "Klawisze modyfikujące łapie tylko
/// CGEventTap, nie NSEvent monitor"). Domyślnie prawy ⌘ (`kVK_RightCommand =
/// 0x36`), konfigurowalny przez `keyCode`.
///
/// Wymaga uprawnienia Dostępność (i/lub "Monitorowanie danych wejściowych") —
/// bez niego `CGEvent.tapCreate` zwraca nil i `start()` zwraca false.
final class HotkeyMonitor {
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "HotkeyMonitor")

    /// Bity "device dependent flags" (IOLLEvent.h) — pozwalają odróżnić
    /// lewy/prawy modyfikator z tym samym `keyCode` bez śledzenia stanu ręcznie.
    private static let deviceFlagMasks: [CGKeyCode: UInt64] = [
        0x36: 0x10, // right command
        0x37: 0x08, // left command
        0x3D: 0x40, // right option
        0x3A: 0x20, // left option
        0x3C: 0x04, // right shift
        0x38: 0x02, // left shift
        0x3E: 0x2000, // right control
        0x3B: 0x01, // left control
        0x3F: 0x800000, // Fn (Globe) — ZMIERZONE sondą 2026-08-09 na fizycznej
        // klawiaturze Wojtka (keyCode=63/0x3F, bit różnicowy 0x800000), nie
        // zgadywane — poprzednie 3 próby innych klawiszy padły w praktyce.
    ]

    /// Klawisz, który uzbraja hold-to-talk. Czytany NA ŻYWO w `handle(...)`
    /// (nie kopiowany do lokalnej stałej przy `start()`), więc zmiana w locie
    /// (np. z Ustawień) działa bez restartu apki i bez zdejmowania tapa.
    var keyCode: CGKeyCode

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    /// Fn+Z: jeden klik zaczyna dyktowanie, kolejny kończy — bez trzymania.
    /// Osobna, ODPORNA ścieżka obok gołego Fn: zwykłe `keyDown` litery z
    /// flagą Fn zawsze dochodzi, podczas gdy samo stuknięcie Fn bywa
    /// połykane przez systemową akcję klawisza Globe (zaobserwowane w logu
    /// 2026-08-12: puszczenie doszło, wciśnięcia nigdy nie było).
    var onToggleChord: (() -> Void)?
    /// Kod litery przełącznika: 6 = „Z" (układ PL/US).
    var toggleKeyCode: CGKeyCode = 6

    private(set) var isDown = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Zaobserwowane 2026-08-09: prawy ⌥ potrafił "odpalić się" ~10x w 9s bez
    /// świadomego przytrzymania — prawdopodobnie efekt uboczny normalnego
    /// użycia klawisza modyfikującego gdzie indziej w systemie. Krótsze niż to
    /// przełączenie stanu jest szumem, nie zamierzonym wciśnięciem — nikt nie
    /// puszcza i wciska ten sam klawisz świadomie w mniej niż 100ms.
    private var lastTransitionAt: CFTimeInterval = 0
    private let debounceInterval: CFTimeInterval = 0.1
    /// Bezpiecznik: jeśli klawisz "trzyma się" wciśnięty dłużej niż to, sam się
    /// puszcza. Zaobserwowane 2026-08-09: prawdziwa sesja dyktowania zostawiła
    /// `isDown=true` NA STAŁE (puszczenie Fn nigdy nie doszło), co zostawiło
    /// mikrofon systemowy przekierowany na ciszę do RĘCZNEGO naprawienia poza
    /// aplikacją. Najbardziej prawdopodobna przyczyna naprawiona niżej
    /// (`.tapDisabledByTimeout` re-enable), ale ten zegar broni się na wszelki
    /// wypadek — mikrofon NIGDY nie zostaje uwięziony na dłużej niż to.
    private var watchdogTimer: Timer?
    private let maxHoldDuration: TimeInterval = 45
    /// Dedykowany wątek tapa — patrz komentarz przy `start()`.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var shouldStopThread = false
    private var tapCreationResult = false
    private let startSemaphore = DispatchSemaphore(value: 0)

    init(keyCode: CGKeyCode = 0x36) {
        self.keyCode = keyCode
    }

    /// Wymaga uprawnienia. Zwraca false, jeśli tap się nie utworzył.
    ///
    /// PRZYCZYNA ŹRÓDŁOWA awarii z 2026-08-09 ("nic nie działa totalnie"):
    /// tap był podpięty pod GŁÓWNĄ pętlę zdarzeń. `beginUtterance()` blokuje
    /// główny wątek na setki milisekund (`AVAudioEngine.start()`, CoreAudio,
    /// zapytania AX) — w tym czasie tap NIE JEST OBSŁUGIWANY i macOS gubi
    /// zdarzenia. Zmierzone: przy naciśnięciu i puszczeniu klawisza docierało
    /// TYLKO wciśnięcie, puszczenie znikało. Efekt: sesja bez końca, mikrofon
    /// systemowy uwięziony na ciszy.
    ///
    /// Przeniesienie pracy przez `DispatchQueue.main.async` NIE pomagało — to
    /// wciąż ten sam wątek. Tap musi mieć WŁASNY wątek z własną pętlą zdarzeń,
    /// niezależny od tego, jak długo zajęty jest główny.
    @discardableResult
    func start() -> Bool {
        stop()

        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask: CGEventMask =
                (1 << CGEventType.flagsChanged.rawValue) |
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue)

            let refcon = Unmanaged.passUnretained(self).toOpaque()

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            ) else {
                self.log.error("CGEventTap creation failed — brak uprawnienia Dostępność/Monitorowanie danych wejściowych")
                DebugLog.write("Hotkey", "CGEventTap creation FAILED")
                self.tapCreationResult = false
                self.startSemaphore.signal()
                return
            }

            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.log.info("HotkeyMonitor started on dedicated thread, keyCode=\(self.keyCode, privacy: .public)")
            DebugLog.write("Hotkey", "tap wystartował na własnym wątku, keyCode=\(self.keyCode)")
            self.tapCreationResult = true
            self.startSemaphore.signal()

            // Własna pętla zdarzeń — żyje niezależnie od obciążenia głównego wątku.
            while !self.shouldStopThread {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        thread.name = "io.github.avejapl.voiceflow.hotkey"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        shouldStopThread = false
        thread.start()

        // Czekamy na wynik utworzenia tapa, żeby `start()` dalej zwracał
        // prawdę/fałsz synchronicznie (AppDelegate na tym polega, żeby pokazać
        // komunikat o brakującym uprawnieniu).
        _ = startSemaphore.wait(timeout: .now() + 2)
        return tapCreationResult
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let loop = tapRunLoop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        shouldStopThread = true
        if let loop = tapRunLoop {
            CFRunLoopStop(loop)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handlePlainKey(event, down: true)
        case .keyUp:
            handlePlainKey(event, down: false)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // PRAWDOPODOBNA PRZYCZYNA realnego zawieszenia 2026-08-09: system
            // wyłącza tap, jeśli callback (albo cokolwiek na głównym wątku,
            // np. start silnika audio w `beginUtterance()`) reaguje za wolno.
            // Bez tego wznowienia WSZYSTKIE kolejne zdarzenia — łącznie z
            // puszczeniem klawisza — znikały w próżni aż do ręcznego restartu.
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            log.error("CGEventTap wyłączony przez system (\(reason, privacy: .public)) — wznawiam")
            DebugLog.write("Hotkey", "CGEventTap disabled (\(reason)) — re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        DebugLog.write("HotkeyRaw", "flagsChanged keyCode=\(eventKeyCode) flags=0x\(String(event.flags.rawValue, radix: 16)) (szukam keyCode=\(keyCode), isDown=\(isDown))")
        guard eventKeyCode == Int64(keyCode) else { return }
        let mask = Self.deviceFlagMasks[keyCode] ?? 0
        let downNow: Bool
        if mask != 0 {
            downNow = (event.flags.rawValue & mask) != 0
        } else {
            // Klawisz spoza tablicy device-flag: przybliżenie po ogólnej masce ⌘/⌥/⌃/⇧.
            downNow = !event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
        }
        setDown(downNow)
    }

    private func handlePlainKey(_ event: CGEvent, down: Bool) {
        let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Fn+Z (przełącznik) — łapiemy WCIŚNIĘCIE litery z aktywną flagą Fn.
        // Debounce ten sam co dla głównego klawisza: auto-repeat trzymanej
        // litery nie może przełączać dyktowania co 30 ms.
        if down, eventKeyCode == Int64(toggleKeyCode),
           event.flags.contains(.maskSecondaryFn),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DebugLog.write("Hotkey", "Fn+Z — przełącznik dyktowania")
            DispatchQueue.main.async { [weak self] in self?.onToggleChord?() }
            return
        }
        guard eventKeyCode == Int64(keyCode) else { return }
        setDown(down)
    }

    private func setDown(_ down: Bool) {
        guard down != isDown else { return }
        let now = CACurrentMediaTime()
        // Filtr szumu TYLKO dla wciśnięcia. PUSZCZENIE musi przejść ZAWSZE.
        //
        // Bug wprowadzony przy naprawianiu samoistnego odpalania prawego ⌥
        // (2026-08-09) i natychmiast gorszy od problemu, który naprawiał:
        // przy szybkim stuknięciu klawisza (< 100 ms) wciśnięcie przechodziło,
        // a puszczenie było odrzucane jako "szum" — sesja zostawała otwarta
        // NA ZAWSZE, z mikrofonem systemowym uwięzionym na ciszy.
        //
        // Kierunek "puszczam" jest krytyczny dla bezpieczeństwa (kończy sesję,
        // przywraca mikrofon i głośność) — nigdy go nie filtrujemy.
        if down {
            guard now - lastTransitionAt >= debounceInterval else {
                log.debug("Ignoruję wciśnięcie skrótu — za szybko po poprzednim (szum)")
                DebugLog.write("Hotkey", "wciśnięcie odrzucone jako szum (< \(debounceInterval)s od poprzedniego)")
                return
            }
        }
        lastTransitionAt = now
        isDown = down
        watchdogTimer?.invalidate()

        // PRZYCZYNA ŹRÓDŁOWA awarii z 2026-08-09 ("nic nie działa totalnie"):
        // `onPressed`/`onReleased` robią SETKI MILISEKUND pracy —
        // `AVAudioEngine.start()`, przełączanie urządzeń CoreAudio, zapytania
        // AX, a `DiscordMuteToggle` ma nawet celowe `usleep(20ms)`. Wywoływane
        // SYNCHRONICZNIE z callbacku CGEventTap blokowały go na tyle długo, że
        // macOS wyłączał tap (`.tapDisabledByTimeout` — potwierdzone w logu)
        // i GUBIŁ puszczenie klawisza. Efekt: sesja nie kończyła się nigdy,
        // mikrofon systemowy zostawał przekierowany na ciszę.
        //
        // Callback tapa MUSI wracać natychmiast. Cała realna praca idzie
        // asynchronicznie na główną kolejkę — wykona się w następnej iteracji
        // pętli zdarzeń, już po powrocie z callbacku.
        if down {
            DispatchQueue.main.async { [weak self] in self?.onPressed?() }
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: maxHoldDuration, repeats: false) { [weak self] _ in
                guard let self, self.isDown else { return }
                self.log.error("Bezpiecznik: klawisz \"wciśnięty\" dłużej niż \(self.maxHoldDuration, privacy: .public)s bez puszczenia — wymuszam zwolnienie")
                DebugLog.write("Hotkey", "Bezpiecznik: wymuszone zwolnienie po \(self.maxHoldDuration)s bez realnego puszczenia klawisza")
                self.setDown(false)
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onReleased?() }
        }
    }
}
