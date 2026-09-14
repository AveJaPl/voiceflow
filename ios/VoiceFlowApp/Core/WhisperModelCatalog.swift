import Foundation

/// Który model whisper (Core ML, repo `argmaxinc/whisperkit-coreml`) dostaje
/// dany telefon. Czysta funkcja, bez zależności od WhisperKit — testowalna
/// na Macu.
///
/// Zasada: ten sam model co na Macu (`large-v3-turbo`) wszędzie tam, gdzie
/// WhisperKit go wspiera (A16/A17 Pro/A18 i nowsze, czyli iPhone 15 Pro w
/// górę — z tablicy `fallbackModelSupportConfig` w WhisperKit), `small` na
/// starszych, `base` jako ostatnia deska ratunku. Użytkownik może zmienić
/// w Ustawieniach → Zaawansowane; domyślnie nie musi wiedzieć, że model
/// w ogóle istnieje.
enum WhisperModelCatalog {
    struct Model: Equatable, Identifiable {
        /// Nazwa wariantu w repo WhisperKit (i nazwa katalogu na dysku).
        let variant: String
        let title: String
        let detail: String
        let approximateMB: Int

        var id: String { variant }
    }

    static let largeTurbo = Model(
        variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
        title: "large-v3-turbo",
        detail: "Najdokładniejszy, ten sam co na Macu. iPhone 15 Pro i nowsze.",
        approximateMB: 632
    )
    static let small = Model(
        variant: "openai_whisper-small",
        title: "small",
        detail: "Rozsądny środek dla starszych telefonów.",
        approximateMB: 216
    )
    static let base = Model(
        variant: "openai_whisper-base",
        title: "base",
        detail: "Najlżejszy, najsłabszy.",
        approximateMB: 74
    )

    static let all: [Model] = [largeTurbo, small, base]

    static func model(variant: String) -> Model? {
        all.first { $0.variant == variant }
    }

    /// Wybór domyślny na podstawie listy wariantów, które WhisperKit uznaje za
    /// wspierane na tym urządzeniu (`WhisperKit.recommendedModels().supported`).
    static func defaultModel(supported: [String]) -> Model {
        if supported.contains(largeTurbo.variant) { return largeTurbo }
        if supported.contains(small.variant) { return small }
        return base
    }
}
