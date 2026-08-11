import Foundation

/// Kontener i rozszerzenie klawiatury komunikują się WYŁĄCZNIE przez App Group
/// UserDefaults — nie ma publicznego API do bezpośredniego IPC między nimi.
/// To jest też jedyny sposób, w jaki kontener może wiedzieć "czy klawiatura
/// kiedykolwiek się uruchomiła" (patrz docs/plans/ios-voiceflow-app.md §3) —
/// samo dodanie klawiatury w Ustawieniach nie generuje żadnego zdarzenia,
/// które apka mogłaby zaobserwować; jedyny sygnał to sama klawiatura
/// zapisująca coś przy starcie.
enum AppGroup {
    static let identifier = "group.io.github.avejapl.voiceflow.ios"

    static var defaults: UserDefaults {
        guard let d = UserDefaults(suiteName: identifier) else {
            // Brak App Group w profilu provisioning — błąd konfiguracji, nie
            // środowiska użytkownika, więc crash tu jest właściwy (fail loud
            // podczas developmentu zamiast cichego rozjazdu stanu).
            fatalError("App Group \(identifier) niedostępna — sprawdź entitlements obu targetów.")
        }
        return d
    }
}

enum AppGroupKeys {
    /// `true` jeśli `KeyboardViewController.viewDidLoad()` uruchomił się
    /// choć raz — jedyny sygnał, że użytkownik dodał klawiaturę w Ustawieniach
    /// i faktycznie ją otworzył (nie tylko włączył przełącznik).
    static let keyboardHasLaunched = "keyboardHasLaunchedEver"

    /// Odświeżane przy każdym pojawieniu się klawiatury: `hasFullAccess`
    /// zaobserwowany w danej chwili. Może się zmieniać w dwie strony
    /// (użytkownik może wyłączyć Pełny Dostęp ponownie), więc to jest stan
    /// "ostatnio zaobserwowany", nie flaga typu "kiedykolwiek".
    static let keyboardHasFullAccessObserved = "keyboardHasFullAccessObserved"

    /// Czy `AVAudioEngine.start()` w rozszerzeniu powiódł się choć raz —
    /// realny wynik kryterium weryfikacji #4 z planu, zapisywany przez
    /// rozszerzenie, czytany przez apkę (np. do przyszłego ekranu diagnostyki).
    static let keyboardMicEngineStartSucceeded = "keyboardMicEngineStartSucceeded"

    /// Ostatni komunikat błędu z uruchomienia silnika audio w klawiaturze
    /// (np. kod błędu 561145187 z dokumentacji Apple) — do debugowania bez
    /// potrzeby podpinania Console.app do telefonu.
    static let keyboardMicEngineLastError = "keyboardMicEngineLastError"

    /// Historia dyktowań (JSON-encoded `[DictationEntry]`) — współdzielona
    /// między ekranem dyktowania w apce (plan B) a przyszłym użyciem przez
    /// klawiaturę, gdyby też miała zapisywać do historii.
    static let dictationHistory = "dictationHistory"

    /// PIVOT #2 (docs/plans/ios-voiceflow-app.md §7): mikrofon w rozszerzeniu
    /// klawiatury jest zablokowany przez sandbox iOS, więc dyktowanie
    /// faktycznie dzieje się w apce kontenerowej (otwartej przez klawiaturę
    /// przez `extensionContext?.open(url: voiceflow://dictate)`). Finalny
    /// tekst czeka tutaj na klawiaturę, która wstawia go automatycznie przy
    /// najbliższym `viewWillAppear` — patrz `PendingInsert.shouldInsert`.
    static let pendingInsertText = "pendingInsertText"

    /// Znacznik czasu zapisu `pendingInsertText` — używany do progu świeżości
    /// (patrz `PendingInsert.freshWindow`), żeby stary, nieodebrany tekst nie
    /// wstawił się nagle w zupełnie innym kontekście dużo później.
    static let pendingInsertAt = "pendingInsertAt"
}
