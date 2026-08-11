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

    /// Wołane RAZ, w `WhisperSpeechEngine.prewarm()`, poza głównym wątkiem —
    /// ładowanie modelu `base` (~148 MB) trwa setki ms (patrz `etap0e-wyniki.md`
    /// §3, kolumna "model load").
    static func load(modelPath: String) throws -> WhisperContext {
        ggml_backend_load_all()
        let params = whisper_context_default_params()
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
