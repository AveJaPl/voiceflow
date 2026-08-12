import SwiftUI
import AppKit

/// Klucze UserDefaults — te SAME, których czytają `AudioDucker` i
/// `DiscordMuteToggle` (Core/), żeby ustawienia i mechanizm nigdy się nie
/// rozjechały. Zmiana tutaj działa NATYCHMIAST, bo obie klasy czytają
/// UserDefaults na żywo przy każdym `start()`, nie raz przy starcie aplikacji.
enum SettingsKeys {
    static let duckingEnabled = "voiceflow.audioDuckingEnabled"
    static let duckVolume = "voiceflow.duckVolume"
    static let discordKeyCode = "voiceflow.discordMuteHotkeyKeyCode"
    static let discordModifierFlags = "voiceflow.discordMuteHotkeyModifierFlags"
    static let insertionMode = "voiceflow.insertionMode"
    /// Transkrypcja na żywo w pillu. Wyłączona = whisper NIE dekoduje w trakcie
    /// mówienia (co 300 ms), tylko raz, na końcu — mikrofon zbiera samo audio.
    /// Na maszynie bez zapasu mocy to jest różnica między „mieli" a „nie mieli".
    static let livePreview = "voiceflow.livePreviewEnabled"
    static let language = "voiceflow.language"
    static let mainHotkeyKeyCode = "voiceflow.mainHotkeyKeyCode"
    static let speechEngine = "voiceflow.speechEngine"
    /// Model whisper.cpp — patrz `WhisperModelChoice` po pomiary, na których
    /// oparto domyślny wybór.
    static let whisperModel = "voiceflow.whisperModel"
    static let micIsolationEnabled = "voiceflow.micIsolationEnabled"
    static let pillPositionX = "voiceflow.pillPositionX"
    static let pillPositionY = "voiceflow.pillPositionY"
    static let customVocabulary = "voiceflow.customVocabulary"
    static let discordPresenceEnabled = "voiceflow.discordPresenceEnabled"
    static let discordPresenceClientID = "voiceflow.discordPresenceClientID"
    static let remoteMicEnabled = "voiceflow.remoteMicEnabled"
    static let remoteMicHost = "voiceflow.remoteMicHost"
    // Wspólny pokój dyktowania — jedyna część aplikacji, która cokolwiek wysyła
    // poza tę maszynę, i wyłącznie zdarzenia obecności oraz liczby.
    static let roomEnabled = "voiceflow.roomEnabled"
    static let roomServer = "voiceflow.roomServer"
    static let roomCode = "voiceflow.roomCode"
    static let roomToken = "voiceflow.roomToken"
    static let roomDuckForOthers = "voiceflow.roomDuckForOthers"
    static let roomDisplayName = "voiceflow.roomDisplayName"
}

/// Modyfikator do przytrzymania jako główny skrót dyktowania. TYLKO klawisze
/// modyfikujące (nie kombinacje z literą jak przy Discordzie) — trzymamy
/// jeden z nich, to jest cała semantyka hold-to-talk.
///
/// Prawy ⌘ (poprzedni domyślny) leży dosłownie obok Return/Enter — realnie
/// zaobserwowane 2026-08-09: koliduje z ⌘+Enter (częste w czatach, np. wysyłka
/// wiadomości), bo prawa ręka naturalnie sięga po PRAWY ⌘ przy tym skrócie.
/// Prawy ⌥ jest teraz domyślny — nic powszechnego nie używa go jako modyfikatora.
enum MainHotkey: String, CaseIterable, Identifiable {
    /// Fn/Globe — TEN SAM wybór co Wispr Flow i wbudowane Dyktowanie Apple,
    /// właśnie dlatego że prawie nic go nie używa jako pojedynczego
    /// modyfikatora. keyCode i bit ZMIERZONE sondą 2026-08-09 (nie zgadywane),
    /// patrz Hotkey/HotkeyMonitor.swift.
    case fn
    /// F5 — klawisz z symbolem mikrofonu na klawiaturach MacBooków. UWAGA:
    /// żeby słał zwykłe `keyDown` F5, w Ustawieniach systemowych musi być
    /// włączone „Używaj klawiszy F1, F2… jako standardowych" ALBO wciskany
    /// razem z Fn; do tego skrót systemowego Dyktowania Apple trzeba
    /// wyłączyć, inaczej podwójne stuknięcie odpala dyktowanie Apple.
    case f5
    case rightOption
    case rightControl
    case rightShift
    case rightCommand
    case leftControl

    var id: String { rawValue }

    var keyCode: CGKeyCode {
        switch self {
        case .fn: 0x3F
        case .f5: 0x60
        case .rightOption: 0x3D
        case .rightControl: 0x3E
        case .rightShift: 0x3C
        case .rightCommand: 0x36
        case .leftControl: 0x3B
        }
    }

    static func from(keyCode: CGKeyCode) -> MainHotkey {
        allCases.first { $0.keyCode == keyCode } ?? .fn
    }

    var label: String {
        switch self {
        case .fn: "Fn / 🌐 (zalecane — jak Wispr Flow i Dyktowanie Apple)"
        case .f5: "F5 / klawisz mikrofonu — wymaga „F1, F2… jako standardowe” i wyłączenia skrótu Dyktowania Apple"
        case .rightOption: "Prawy ⌥ — u Ciebie odpalał się samoistnie"
        case .rightControl: "Prawy ⌃ — może nie istnieć na Twojej klawiaturze"
        case .rightShift: "Prawy ⇧"
        case .rightCommand: "Prawy ⌘ — koliduje z ⌘+Enter w wielu aplikacjach"
        case .leftControl: "Lewy ⌃ — koliduje z Ctrl+A/E/K (nawigacja w polu tekstowym)"
        }
    }
}

/// Silnik rozpoznawania mowy dla polskiego (angielski zawsze zostaje na Apple —
/// docs/plans/whisper-local-engine-pl.md, "nie ma dziś żadnego znanego problemu
/// z tą ścieżką, nie dotykać"). Nazwa celowo INNA niż protokół `SpeechEngine`
/// z `Core/SpeechEngine.swift`, żeby ich nie mylić.
enum SpeechEngineChoice: String, CaseIterable, Identifiable {
    /// Domyślny od 2026-08-10 — lokalnie, offline, zero zależności od serwera
    /// Apple (patrz nagłówek pliku VoiceFlowApp.swift o awarii, która to wymusiła).
    case whisper
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whisper: "whisper.cpp (offline, na urządzeniu) — zalecane"
        case .apple: "Apple (serwer, wymaga sieci)"
        }
    }
}

/// Trzyma ustawienia widoczne dla użytkownika, czytane/zapisywane bezpośrednio
/// do UserDefaults — bez tego pośredniego kroku zmiana w formularzu i realne
/// zachowanie `AudioDucker`/`DiscordMuteToggle` mogłyby się rozjechać.
final class SettingsModel: ObservableObject {
    @Published var duckingEnabled: Bool {
        didSet { defaults.set(duckingEnabled, forKey: SettingsKeys.duckingEnabled) }
    }
    /// 0...1 — jak GŁOŚNO zostaje audio w tle (0.2 = przyciszone do 20%).
    @Published var duckVolume: Double {
        didSet { defaults.set(duckVolume, forKey: SettingsKeys.duckVolume) }
    }
    @Published var discordHotkey: RecordedHotkey? {
        didSet {
            if let discordHotkey {
                defaults.set(Int(discordHotkey.keyCode), forKey: SettingsKeys.discordKeyCode)
                defaults.set(Int(discordHotkey.flags.rawValue), forKey: SettingsKeys.discordModifierFlags)
            } else {
                defaults.removeObject(forKey: SettingsKeys.discordKeyCode)
                defaults.removeObject(forKey: SettingsKeys.discordModifierFlags)
            }
        }
    }
    @Published var livePreview: Bool {
        didSet { defaults.set(livePreview, forKey: SettingsKeys.livePreview) }
    }

    @Published var insertionMode: InsertionMode {
        didSet { defaults.set(insertionMode.rawValue, forKey: SettingsKeys.insertionMode) }
    }
    @Published var language: DictationLanguage {
        didSet { defaults.set(language.rawValue, forKey: SettingsKeys.language) }
    }
    /// Zmiana wymaga restartu — silnik tworzy się raz, przy starcie
    /// (`VoiceFlowApp.setupSessionController`), tak samo jak `language` wyżej.
    @Published var whisperModel: WhisperModelChoice {
        didSet { defaults.set(whisperModel.rawValue, forKey: SettingsKeys.whisperModel) }
    }

    @Published var speechEngine: SpeechEngineChoice {
        didSet { defaults.set(speechEngine.rawValue, forKey: SettingsKeys.speechEngine) }
    }
    /// Zmiana działa NATYCHMIAST, bez restartu — `HotkeyMonitor.keyCode` czyta
    /// się na żywo (patrz komentarz w Hotkey/HotkeyMonitor.swift). AppDelegate
    /// nasłuchuje tej zmiany i podmienia `keyCode` na żywym monitorze.
    @Published var mainHotkey: MainHotkey {
        didSet { defaults.set(Int(mainHotkey.keyCode), forKey: SettingsKeys.mainHotkeyKeyCode) }
    }
    /// Domyślnie WYŁĄCZONE — wymaga zainstalowanego BlackHole (§Core/
    /// InputDeviceSwitcher) i ustawienia Discorda na "Domyślne" urządzenie
    /// wejściowe. Nie zgadujemy, że to zrobione — użytkownik włącza jawnie.
    @Published var micIsolationEnabled: Bool {
        didSet { defaults.set(micIsolationEnabled, forKey: SettingsKeys.micIsolationEnabled) }
    }
    /// Nazwy własne, które ASR często myli (§Zadanie 1 audytu — `model
    /// .vocabulary` z config.yaml Linuksa). whisper.cpp dostaje je od razu
    /// (`WhisperSpeechEngine` czyta UserDefaults na żywo przy każdym oknie),
    /// Apple-engine dopiero po restarcie (`Formatter` budowany raz przy
    /// starcie, patrz `VoiceFlowApp.setupSessionController`).
    @Published var customVocabulary: [String] {
        didSet { defaults.set(customVocabulary, forKey: SettingsKeys.customVocabulary) }
    }
    /// Discord Rich Presence (§Zadanie 3 audytu — `presence.enabled` z
    /// config.yaml Linuksa). Działa na żywo, bez restartu — `DiscordPresence`
    /// czyta UserDefaults przy każdym `start()`/`stop()`.
    @Published var discordPresenceEnabled: Bool {
        didSet { defaults.set(discordPresenceEnabled, forKey: SettingsKeys.discordPresenceEnabled) }
    }
    @Published var discordPresenceClientID: String {
        didSet { defaults.set(discordPresenceClientID, forKey: SettingsKeys.discordPresenceClientID) }
    }
    /// Zdalny mikrofon (telefon) — §remote-mic-relay planu. Domyślnie
    /// WYŁĄCZONE — nowa, niesprawdzona ścieżka sieciowa (ten sam wzorzec co
    /// `micIsolationEnabled` wyżej: użytkownik włącza jawnie).
    @Published var remoteMicEnabled: Bool {
        didSet { defaults.set(remoteMicEnabled, forKey: SettingsKeys.remoteMicEnabled) }
    }
    /// Adres relaya — pełny URL ze schematem (`wss://…`, albo `ws://…` do
    /// testu lokalnego) lub sam host (domyślnie `wss://`), patrz
    /// `RemoteMicClient.relayURL(from:token:)`.
    @Published var remoteMicHost: String {
        didSet { defaults.set(remoteMicHost, forKey: SettingsKeys.remoteMicHost) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: SettingsKeys.mainHotkeyKeyCode) != nil {
            self.mainHotkey = MainHotkey.from(keyCode: CGKeyCode(defaults.integer(forKey: SettingsKeys.mainHotkeyKeyCode)))
        } else {
            // TRZECIA zmiana domyślnego (2026-08-09): ⌘ kolidował z ⌘+Enter,
            // ⌥ odpalał się samoistnie ~10x/9s, prawy ⌃ nie istnieje na
            // klawiaturze Wojtka. Fn zmierzone sondą (keyCode=63/0x3F,
            // bit=0x800000) — ten sam wybór co Wispr Flow i Dyktowanie Apple.
            self.mainHotkey = .fn
            defaults.set(Int(MainHotkey.fn.keyCode), forKey: SettingsKeys.mainHotkeyKeyCode)
        }
        self.micIsolationEnabled = defaults.bool(forKey: SettingsKeys.micIsolationEnabled)
        self.duckingEnabled = defaults.object(forKey: SettingsKeys.duckingEnabled) == nil
            ? true : defaults.bool(forKey: SettingsKeys.duckingEnabled)
        let storedDuck = defaults.object(forKey: SettingsKeys.duckVolume) as? Double
        self.duckVolume = (storedDuck.map { $0 > 0 && $0 < 1 } ?? false) ? storedDuck! : 0.2
        if defaults.object(forKey: SettingsKeys.discordKeyCode) != nil {
            let keyCode = CGKeyCode(defaults.integer(forKey: SettingsKeys.discordKeyCode))
            let flags = CGEventFlags(rawValue: UInt64(defaults.integer(forKey: SettingsKeys.discordModifierFlags)))
            self.discordHotkey = RecordedHotkey(keyCode: keyCode, flags: flags)
        } else {
            // NIE ustawiamy nic domyślnie. Wcześniej wpisywaliśmy tu stockowe
            // ⌘⇧M — przez co aplikacja wysyłała je przy każdym dyktowaniu,
            // nawet po ręcznym skasowaniu ustawienia (init nadpisywał je z
            // powrotem przy starcie). Efekt: Discord wyciszał się bez zgody
            // użytkownika i nie zawsze odciszał. Skrót wyłącznie jawnie
            // nagrany przez użytkownika.
            self.discordHotkey = nil
        }
        self.livePreview = defaults.object(forKey: SettingsKeys.livePreview) == nil
            ? true
            : defaults.bool(forKey: SettingsKeys.livePreview)
        self.insertionMode = defaults.string(forKey: SettingsKeys.insertionMode)
            .flatMap(InsertionMode.init(rawValue:)) ?? .liveTyping
        self.language = defaults.string(forKey: SettingsKeys.language)
            .flatMap(DictationLanguage.init(rawValue:)) ?? .polish
        self.whisperModel = WhisperModelChoice.current(defaults)
        self.speechEngine = defaults.string(forKey: SettingsKeys.speechEngine)
            .flatMap(SpeechEngineChoice.init(rawValue:)) ?? .whisper
        self.customVocabulary = defaults.stringArray(forKey: SettingsKeys.customVocabulary) ?? []
        self.discordPresenceEnabled = defaults.bool(forKey: SettingsKeys.discordPresenceEnabled)
        self.discordPresenceClientID = defaults.string(forKey: SettingsKeys.discordPresenceClientID) ?? ""
        self.remoteMicEnabled = defaults.bool(forKey: SettingsKeys.remoteMicEnabled)
        self.remoteMicHost = defaults.string(forKey: SettingsKeys.remoteMicHost) ?? ""
    }
}

/// Ustawienia: skrót, język, tryb wstawiania, przyciszanie audio, wyciszanie
/// Discorda. Formularz systemowy — bez ozdobnych fontów, bez emotek.
/// Kategorie ustawień — jedna lista po lewej zamiast jednego długiego zwoju.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case dictation, insertion, audio, vocabulary, room, remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dyktowanie"
        case .insertion: "Wstawianie tekstu"
        case .audio: "Dźwięk"
        case .vocabulary: "Słownik"
        case .room: "Wspólny pokój"
        case .remote: "Zdalny mikrofon"
        }
    }

    var icon: String {
        switch self {
        case .dictation: "mic"
        case .insertion: "text.cursor"
        case .audio: "speaker.wave.2"
        case .vocabulary: "character.book.closed"
        case .room: "person.2"
        case .remote: "iphone"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var remoteMic: RemoteMicClient
    @State private var adminSecretInput = ""
    @State private var pairingStatus: String?
    @State private var isPairing = false
    @State private var category: SettingsCategory = .dictation

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Divider()
            Form {
                switch category {
                case .dictation: dictationSections
                case .insertion: insertionSections
                case .audio: audioSections
                case .vocabulary: vocabularySections
                case .room: roomSections
                case .remote: remoteSections
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 620)
    }

    /// Lewa kolumna z kategoriami. Powód przebudowy: wcześniej wszystkie
    /// jedenaście sekcji leżało w jednej kolumnie, jedna pod drugą, w oknie
    /// wysokim na 900 punktów — żeby zmienić model, trzeba było przewinąć obok
    /// Discorda, izolacji mikrofonu i słownika. Kategorie po lewej pokazują naraz
    /// tylko to, czego user szuka, i dają nazwom sekcji hierarchię, której płaska
    /// lista nie miała.
    private var categorySidebar: some View {
        List(SettingsCategory.allCases, selection: $category) { item in
            Label(item.title, systemImage: item.icon)
                .tag(item)
        }
        .listStyle(.sidebar)
        .frame(width: 190)
    }

    @ViewBuilder
    private var dictationSections: some View {
            Section("Skrót") {
                Picker("Przytrzymaj, aby dyktować", selection: $model.mainHotkey) {
                    ForEach(MainHotkey.allCases) { hotkey in
                        Text(hotkey.label).tag(hotkey)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Zmiana działa od razu, bez restartu aplikacji. Prawy ⌘ bywa tym samym klawiszem, którego prawa ręka używa do ⌘+Enter (np. wysyłka wiadomości w czatach) — stąd zalecany prawy ⌥.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Silnik i język") {
                Picker("Silnik rozpoznawania (polski)", selection: $model.speechEngine) {
                    ForEach(SpeechEngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Dotyczy TYLKO polskiego — angielski zawsze idzie przez Apple. Zmiana wymaga restartu VoiceFlow, silnik tworzy się raz przy starcie. whisper.cpp działa w pełni lokalnie i offline (zero zależności od serwera Apple); zalecane po awarii serwera Apple 2026-08-10.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Transkrypcja na żywo w pillu", isOn: $model.livePreview)
                Text("Wyłączona: w trakcie mówienia pill pokazuje tylko falę dźwięku, a whisper liczy RAZ, po puszczeniu skrótu — zamiast dekodować co 300 ms przez całe dyktowanie. Mniej obciążenia, zero różnicy w tekście końcowym (on zawsze powstaje z pełnego przebiegu). Działa od następnej wypowiedzi, bez restartu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("Model whisper.cpp", selection: $model.whisperModel) {
                    ForEach(WhisperModelChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Pomiar na nagraniu 4,3 s (ten Mac, bez GPU — Homebrew'owy whisper.cpp nie ma backendu Metal): base 1,2 s, large-v3-turbo 6,4 s, oba z tym samym, poprawnym tekstem. Większy model bierz na żargon, akcent i hałas. Pierwsze użycie pobiera model (574 MB); zmiana wymaga restartu VoiceFlow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("Język dyktowania", selection: $model.language) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Zmiana języka wymaga restartu aplikacji — silnik rozpoznawania tworzy się raz, przy starcie.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var insertionSections: some View {
            Section("Wstawianie tekstu") {
                Picker("Tryb", selection: $model.insertionMode) {
                    ForEach(InsertionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(insertionModeHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var audioSections: some View {
            Section("Przyciszanie audio w trakcie mówienia") {
                Toggle("Przyciszaj muzykę i inne dźwięki systemowe", isOn: $model.duckingEnabled)
                if model.duckingEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Poziom przyciszenia")
                            Spacer()
                            Text("\(Int((1 - model.duckVolume) * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.duckVolume, in: 0.05...0.6)
                    }
                    Text("Głośność wraca do poprzedniej wartości chwilę po zakończeniu dyktowania — nie migocze między krótkimi przerwami w mówieniu.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Section("Izolacja mikrofonu (Discord i inne czaty)") {
                Toggle("Podczas dyktowania nikt na czacie mnie nie słyszy", isOn: $model.micIsolationEnabled)
                Text("Na czas dyktowania podmienia systemowe domyślne wejście audio na ciche (BlackHole) i przywraca po. Dwa warunki: BlackHole musi być zainstalowany (zrobione, jeśli widzisz ten przełącznik) i Discord musi mieć Urządzenie wejściowe ustawione na „Domyślne” w Ustawienia → Głos i wideo — nie na nazwaną kartę na sztywno. Sprawdź to raz ręcznie w Discordzie, zanim włączysz.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Discord — skrót „Wycisz” (alternatywa)") {
                DiscordHotkeyRecorder(hotkey: $model.discordHotkey)
                Text("Starsza metoda — symuluje przycisk „Wycisz” w Discordzie. Mniej niezawodna niż izolacja mikrofonu wyżej (Discord czasem gubi jedno z dwóch identycznych naciśnięć). Jeśli włączyłeś izolację mikrofonu, ten skrót jest zbędny — możesz zostawić puste (przycisk „Wyczyść”).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Discord — status dyktowania (Rich Presence)") {
                Toggle("Pokazuj w Discordzie, że właśnie dyktuję", isOn: $model.discordPresenceEnabled)
                if model.discordPresenceEnabled {
                    TextField("Client ID aplikacji Discorda", text: $model.discordPresenceClientID)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Wymaga własnej aplikacji założonej na discord.com/developers/applications — to samo pole co „presence.client_id” w konfiguracji Linuksa. Jeśli Discord nie jest uruchomiony albo client ID jest puste, funkcja po prostu nic nie robi.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var vocabularySections: some View {
            Section("Słownik — słowa własne") {
                VocabularyEditor(words: $model.customVocabulary)
                Text("Nazwy własne, które silnik rozpoznawania mowy często myli (np. „Programo”, „Estalo”). Dla whisper.cpp trafiają wprost do promptu dekodera — działa od razu, bez restartu. Dla silnika Apple działają jak wbudowany słownik (poprawka wielkości liter) — wymaga restartu VoiceFlow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var roomSections: some View {
            RoomSettingsSection()
    }

    @ViewBuilder
    private var remoteSections: some View {
            Section("Zdalny mikrofon (telefon)") {
                Toggle("Włącz zdalny mikrofon", isOn: $model.remoteMicEnabled)
                    .onChange(of: model.remoteMicEnabled) { _, _ in remoteMic.restart() }
                TextField("Adres relaya (np. wss://voiceflow-relay.programo.pl)", text: $model.remoteMicHost)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.remoteMicHost) { _, _ in remoteMic.restart() }
                HStack {
                    Text("Status:")
                    Text(connectionStatusLabel)
                        .foregroundStyle(connectionStatusColor)
                }
                .font(.system(size: 12))

                Divider()

                Text("Parowanie — jednorazowe, generuje token w relayu i zapisuje go w Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                SecureField("ADMIN_SECRET relaya (nie zapisywany na dysku)", text: $adminSecretInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(isPairing ? "Parowanie…" : "Sparuj") {
                        pair()
                    }
                    .disabled(isPairing || model.remoteMicHost.isEmpty || adminSecretInput.isEmpty)
                    if let pairingStatus {
                        Text(pairingStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Telefon (osobna apka, oddzielne zadanie) łączy się przez ten sam relay tym samym tokenem. Wojtek trzyma przycisk na telefonie i mówi — tekst trafia do okna, które ma akurat focus na tym Macu, dokładnie jak przy dyktowaniu lokalnym skrótem.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
    }

    private var connectionStatusLabel: String {
        switch remoteMic.connectionState {
        case .disabled: "wyłączony"
        case .connecting: "łączenie…"
        case .connected: "połączono"
        case .disconnected: "rozłączony"
        }
    }

    private var connectionStatusColor: Color {
        switch remoteMic.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .red
        case .disabled: .secondary
        }
    }

    private func pair() {
        isPairing = true
        pairingStatus = nil
        let host = model.remoteMicHost
        let secret = adminSecretInput
        Task {
            do {
                let token = try await RemoteMicPairing.pair(host: host, adminSecret: secret)
                KeychainPairingTokenStore().saveToken(token)
                adminSecretInput = ""
                pairingStatus = "Sparowano — token zapisany w Keychain."
                remoteMic.restart()
            } catch {
                pairingStatus = error.localizedDescription
            }
            isPairing = false
        }
    }

    private var insertionModeHint: String {
        switch model.insertionMode {
        case .liveTyping:
            "Tekst leci pod kursorem w trakcie mówienia. Aplikacje na Electronie (Slack, Discord, Notion, Claude Desktop) i IDE zawsze dostają bezpieczny tryb poniżej, niezależnie od tego ustawienia."
        case .showThenInsert:
            "Tekst widać w pillu, wstawiany jest dopiero po zakończeniu dyktowania — przez schowek, najbardziej niezawodna droga, ale bez podglądu na żywo w polu."
        }
    }
}

/// Skrót klawiszowy zarejestrowany przez `DiscordHotkeyRecorder` — trzyma dość
/// informacji, żeby `DiscordMuteToggle` (Core/) mógł go odtworzyć przez CGEvent.
struct RecordedHotkey: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    var displayString: String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func from(event: NSEvent) -> RecordedHotkey {
        var flags: CGEventFlags = []
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        return RecordedHotkey(keyCode: CGKeyCode(event.keyCode), flags: flags)
    }

    /// Mapowanie zdecydowanej większości klawiszy alfanumerycznych — resztę
    /// (rzadkie klawisze specjalne) pokazujemy jako surowy kod, wystarczające
    /// do rozpoznania "czy to na pewno TA kombinacja", nawet jeśli nazwa
    /// nie jest ładna.
    private static func keyName(for keyCode: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
            12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 29: "0", 49: "Spacja",
        ]
        return names[keyCode] ?? "kod \(keyCode)"
    }
}

/// Widget "kliknij i naciśnij kombinację" — standardowy wzorzec z Ustawień
/// systemowych. Nagrywa lokalny monitor zdarzeń tylko na czas nagrywania,
/// zdejmuje go natychmiast po złapaniu pierwszej sensownej kombinacji.
private struct DiscordHotkeyRecorder: View {
    @Binding var hotkey: RecordedHotkey?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(isRecording ? "Naciśnij kombinację…" : (hotkey?.displayString ?? "Nie ustawiono"))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            Button(isRecording ? "Anuluj" : "Nagraj") {
                isRecording ? stopRecording() : startRecording()
            }
            if hotkey != nil {
                Button("Wyczyść") {
                    hotkey = nil
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Sam Escape bez modyfikatorów = anuluj, nie zapisuj jako skrót.
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                stopRecording()
                return nil
            }
            hotkey = RecordedHotkey.from(event: event)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Lista edytowalna słów/fraz — dodaj, edytuj wiersz tekstowy, usuń. Formularz
/// systemowy, bez ozdobników, spójny z resztą `SettingsView`.
private struct VocabularyEditor: View {
    @Binding var words: [String]

    var body: some View {
        ForEach(words.indices, id: \.self) { index in
            HStack {
                TextField("np. Programo", text: Binding(
                    get: { words[index] },
                    set: { words[index] = $0 }
                ))
                Button {
                    words.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        Button("Dodaj słowo") {
            words.append("")
        }
    }
}
