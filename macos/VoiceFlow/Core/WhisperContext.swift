import Foundation

/// Cienki wrapper Swift nad C API whisper.cpp (`whisper.h`, biblioteka z
/// Homebrew `whisper-cpp` — patrz komentarz w `VoiceFlow-Bridging-Header.h` i
/// `apps/mac/project.yml` dla linkowania). Typy C (`whisper_context`,
/// `whisper_full_params`...) zostają PRYWATNE dla tego pliku — sygnatury
/// widoczne na zewnątrz (nawet `internal`, widziane przez `@testable import`
/// w VoiceFlowTests) używają wyłącznie typów natywnych Swifta, żeby bridging
/// header nie musiał być widoczny poza tym jednym plikiem.
final class WhisperContext {
    private let ctx: OpaquePointer

    enum WhisperContextError: LocalizedError {
        case loadFailed(path: String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let path):
                return "Nie udało się załadować modelu whisper.cpp z \(path)"
            }
        }
    }

    private init(ctx: OpaquePointer) {
        self.ctx = ctx
    }

    /// Ładuje backendy obliczeniowe ggml — **w tym Metal, czyli GPU**.
    ///
    /// To jest różnica między „liczy się kilka sekund" a „liczy się ułamek sekundy",
    /// i przez długi czas w ogóle jej tu nie było.
    ///
    /// W ggml 0.15 backendy nie siedzą w `libggml`, tylko są osobnymi bibliotekami
    /// ładowanymi w czasie działania (`libggml-metal.so`, `libggml-blas.so`,
    /// `libggml-cpu-apple_m2_m3.so`). Gołe `ggml_backend_load_all()` szuka ich
    /// **obok własnego pliku wykonywalnego**: `whisper-cli` leży w
    /// `/opt/homebrew/bin`, więc znajduje wszystko i startuje na Metalu, ale nasz
    /// plik wykonywalny leży w `VoiceFlow.app/Contents/MacOS` i nie znajduje NIC.
    /// Aplikacja liczyła więc nie tylko bez GPU, ale nawet bez zoptymalizowanego
    /// backendu CPU dla Apple Silicon — na ścieżce ogólnej.
    ///
    /// Objaw był całkowicie niemy: żadnego błędu, żadnego ostrzeżenia, po prostu
    /// wielokrotnie dłuższe liczenie.
    private static func loadBackends() {
        for directory in backendSearchPaths() where FileManager.default.fileExists(atPath: directory) {
            directory.withCString { ggml_backend_load_all_from_path($0) }
            DebugLog.write("Whisper", "backendy ggml załadowane z \(directory)")
            return
        }
        // Ostatnia deska ratunku — zachowanie sprzed tej zmiany (samo CPU).
        DebugLog.write("Whisper", "nie znaleziono katalogu backendów ggml — liczenie pójdzie po CPU")
        ggml_backend_load_all()
    }

    /// Najpierw kopia w pakiecie aplikacji (jeśli kiedyś dołączymy backendy do
    /// dystrybucji), potem Homebrew. Kolejność ma znaczenie: pakiet jest naszą
    /// wersją, Homebrew może się zaktualizować pod nami.
    private static func backendSearchPaths() -> [String] {
        var paths: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ggml-backends").path {
            paths.append(bundled)
        }
        paths.append("/opt/homebrew/opt/ggml/libexec")
        paths.append("/usr/local/opt/ggml/libexec")
        return paths
    }

    /// Wołane RAZ, w `WhisperSpeechEngine.prewarm()`, poza głównym wątkiem —
    /// ładowanie modelu `base` (~148 MB) trwa setki ms (patrz `etap0e-wyniki.md`
    /// §3, kolumna "model load").
    static func load(modelPath: String) throws -> WhisperContext {
        loadBackends()
        var params = whisper_context_default_params()
        // Flash attention na Metalu to czysty zysk czasu bez wpływu na wynik —
        // whisper.cpp sam wycofuje się na zwykłą ścieżkę, jeśli backend jej nie
        // wspiera, więc włączenie jest bezpieczne również na czystym CPU.
        params.flash_attn = true
        params.use_gpu = true
        let created = modelPath.withCString { pathPtr in
            whisper_init_from_file_with_params(pathPtr, params)
        }
        guard let created else {
            throw WhisperContextError.loadFailed(path: modelPath)
        }
        return WhisperContext(ctx: created)
    }

    deinit {
        whisper_free(ctx)
    }

    /// Dekoduje `samples` (16 kHz mono float, -1...1) greedy, single-segment —
    /// parametry zmierzone w sondzie (`stream_probe.c`), plus `initialPrompt`
    /// (ostatnie skomitowane słowa) jako kontekst dla dekodera — DODATEK
    /// względem sondy, bo bez niego greedy decoding na krótkich, oderwanych
    /// oknach (`no_context=true`) potrafił halucynować powtórzenie ostatniego
    /// słowa ("porozmawiać i porozmawiać..."), niezależne od precyzji cięcia
    /// audio (patrz komentarz w `WhisperSpeechEngine.decodeStepIfNeeded`) —
    /// zaobserwowane realnie w `testTranscribesWavFixtureInRealTime`. Danie
    /// dekoderowi ostatnich słów jako promptu to standardowa technika
    /// (`whisper.cpp`/`whisper_streaming`) na uziemienie krótkich okien.
    /// NIE jest bezpieczne wywoływać równolegle na tym samym kontekście
    /// (dokumentacja whisper.h: "Not thread safe for same context") —
    /// wołający (`WhisperSpeechEngine`) musi serializować wywołania na
    /// jednej kolejce.
    /// Pełny przebieg po CAŁYM nagraniu wypowiedzi — to jest tekst, który trafia
    /// do użytkownika.
    ///
    /// Odpowiednik `Transcriber.transcribe` z Linuksa (`src/voiceflow/transcriber.py`),
    /// gdzie podgląd na żywo i tekst końcowy to DWA różne przebiegi: pierwszy jest
    /// szybki i niepewny, drugi widzi całe zdanie naraz. macOS tego nie miał — tekst
    /// końcowy był sklejką commitów `LocalAgreement` ze strumienia, więc raz źle
    /// usłyszane słowo zostawało w nim na zawsze.
    ///
    /// Zmierzone na `VoiceFlowTests/Fixtures/dyktowanie-pl.wav` (4,3 s, model `base`,
    /// 2026-08-11) — ten sam model, ta sama maszyna, różnica wyłącznie w sposobie
    /// dekodowania:
    ///   strumień + local-agreement → "Dzień dobry. W chciałbym dzisiaj porozmawiać…"
    ///   pełny przebieg beam 5      → "Dzień dobry, chciałbym dzisiaj porozmawiać…"  (poprawnie)
    /// Koszt: ~1,2 s przy `base`. Dlatego to osobna metoda, wołana RAZ na koniec, a
    /// nie zamiennik `transcribe` w pętli strumienia.
    ///
    /// Różnice względem przebiegu strumieniowego, wszystkie celowe:
    /// - **beam search** zamiast greedy (`beam_size` jak `model.beam_size: 5` na Linuksie),
    /// - **bez `single_segment`** — całe nagranie może mieć wiele zdań,
    /// - **bez `max_tokens`** — limit 64 tokenów obciąłby dłuższą wypowiedź w pół słowa,
    /// - **`no_context = true`** — świeży start, bez pozostałości po oknach strumienia.
    /// - Parameter vadModelPath: ścieżka do modelu Silero VAD (ggml). Gdy podana,
    ///   whisper NAJPIERW wycina ciszę i nie-mowę, a dopiero potem dekoduje —
    ///   odpowiednik `vad_filter=True` z faster-whispera na Linuksie
    ///   (`Transcriber.transcribe`). Dwie korzyści naraz: mniej 30-sekundowych
    ///   okien do policzenia (koszt whispera jest ~stały NA OKNO, nie na sekundę
    ///   mowy) i mniej halucynacji na fragmentach czystej ciszy. `nil` = stare
    ///   zachowanie, używane też celowo w warmupie: VAD odrzuciłby ciszę zanim
    ///   enkoder w ogóle by ruszył i warmup nic by nie rozgrzał (ta sama
    ///   pułapka, którą Linux opisuje w `Transcriber._consume_warmup`).
    func transcribeFull(
        samples: [Float],
        language: String,
        initialPrompt: String = "",
        beamSize: Int32 = 5,
        vadModelPath: String? = nil
    ) -> String {
        guard !samples.isEmpty else { return "" }
        var params: whisper_full_params
        if beamSize <= 1 {
            // Greedy przez właściwą strategię, nie „beam search z wiązką 1" —
            // ta druga forma i tak liczy pełną księgowość wiązki.
            params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        } else {
            params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
            params.beam_search.beam_size = beamSize
        }
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = false
        params.no_context = true
        // `max_tokens = 0` znaczy „bez limitu". Strumień ma 64, bo dekoduje okna po
        // 2 s; tutaj obcięłoby to każdą dłuższą wypowiedź.
        params.max_tokens = 0
        params.n_threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
        params.translate = false
        params.no_timestamps = true
        params.suppress_blank = true

        return language.withCString { languagePtr -> String in
            params.language = languagePtr
            return initialPrompt.withCString { promptPtr -> String in
                if !initialPrompt.isEmpty { params.initial_prompt = promptPtr }
                // `withCString` musi obejmować całe `whisper_full` — wskaźnik
                // do ścieżki VAD żyje tylko wewnątrz tego domknięcia.
                return (vadModelPath ?? "").withCString { vadPtr -> String in
                    if vadModelPath != nil {
                        params.vad = true
                        params.vad_model_path = vadPtr
                        params.vad_params = whisper_vad_default_params()
                    }
                    let rc = samples.withUnsafeBufferPointer { buffer -> Int32 in
                        guard let base = buffer.baseAddress else { return -1 }
                        return whisper_full(ctx, params, base, Int32(buffer.count))
                    }
                    guard rc == 0 else { return "" }

                    var text = ""
                    let segmentCount = whisper_full_n_segments(ctx)
                    for i in 0..<segmentCount {
                        if let segment = whisper_full_get_segment_text(ctx, i) {
                            text += String(cString: segment)
                        }
                    }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    func transcribe(samples: [Float], language: String, initialPrompt: String = "") -> String {
        guard !samples.isEmpty else { return "" }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = true
        params.no_context = true
        params.max_tokens = 64
        params.n_threads = 4
        params.translate = false
        params.no_timestamps = true
        params.suppress_blank = true

        return language.withCString { languagePtr -> String in
            params.language = languagePtr
            return initialPrompt.withCString { promptPtr -> String in
                if !initialPrompt.isEmpty { params.initial_prompt = promptPtr }
                let rc = samples.withUnsafeBufferPointer { buffer -> Int32 in
                    guard let base = buffer.baseAddress else { return -1 }
                    return whisper_full(ctx, params, base, Int32(buffer.count))
                }
                guard rc == 0 else { return "" }

                var text = ""
                let segmentCount = whisper_full_n_segments(ctx)
                for i in 0..<segmentCount {
                    if let segment = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: segment)
                    }
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
