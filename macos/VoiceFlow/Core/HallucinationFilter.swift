import Foundation

/// Ucinanie zmyślonych pożegnań z KOŃCA transkrypcji.
///
/// Whisper jest uczony na napisach z YouTube'a, więc na ciszy albo na oddechu
/// pod koniec nagrania „kończy odcinek", którego nie było: „Dziękuję za
/// oglądanie", „Napisy stworzone przez społeczność Amara.org", „Thanks for
/// watching". Zmierzone w tej aplikacji 2026-08-14: krótka wypowiedź do
/// telefonu wróciła jako „[tłumaczenie na język ukraińskim]".
///
/// Port rozwiązania Filipa z wersji linuksowej (`src/voiceflow/transcriber.py`,
/// `drop_trailing_hallucinations`) — ta sama lista fraz i te same progi, żeby
/// obie aplikacje zachowywały się tak samo.
///
/// TRZY WARUNKI NARAZ, i to jest sedno: (1) tylko znane frazy, (2) tylko z
/// końca, (3) tylko gdy metadane segmentu SAME zdradzają zmyślenie — wysokie
/// prawdopodobieństwo braku mowy albo bardzo niepewne tokeny. Prawdziwe,
/// wypowiedziane „dziękuję" ma metadane pewnego segmentu i przechodzi
/// nietknięte. Bez trzeciego warunku funkcja zjadałaby ludziom słowa, co jest
/// gorsze niż zostawienie halucynacji.
enum HallucinationFilter {

    /// Segment transkrypcji z metadanymi, których whisper.cpp udziela przez
    /// `whisper_full_get_segment_no_speech_prob` i `whisper_full_get_token_p`.
    struct Segment: Equatable {
        let text: String
        /// Prawdopodobieństwo, że w tym segmencie NIE MA mowy (0…1).
        let noSpeechProbability: Float
        /// Średni logarytm prawdopodobieństwa tokenów — im niżej, tym mniej
        /// model był pewny tego, co napisał.
        let averageLogProbability: Float

        init(text: String, noSpeechProbability: Float = 0, averageLogProbability: Float = 0) {
            self.text = text
            self.noSpeechProbability = noSpeechProbability
            self.averageLogProbability = averageLogProbability
        }
    }

    /// Frazy dopisywane do ciszy. Porównanie po normalizacji: małe litery, bez
    /// interpunkcji i bez znaków diakrytycznych.
    static let farewells: Set<String> = [
        "dziekuje", "dziekuje bardzo", "dzieki",
        "dziekuje za ogladanie", "dzieki za ogladanie", "dziekuje za uwage",
        "dziekuje za ogladanie i do zobaczenia",
        "do zobaczenia", "do zobaczenia w nastepnym odcinku",
        "do zobaczenia w kolejnym odcinku", "zapraszam na kolejny film",
        "zapraszam do subskrypcji", "zasubskrybuj", "milego dnia", "na razie",
        "napisy stworzone przez spolecznosc amaraorg",
        "napisy stworzone przez spolecznosc amara org",
        "napisy robione przez spolecznosc amaraorg",
        "thank you", "thanks for watching", "thank you for watching",
        "thank you for watching and see you next time", "see you next time", "bye",
        // Ta padła u nas na żywo: model „przetłumaczył" ciszę na komunikat
        // o tłumaczeniu.
        "tlumaczenie na jezyk ukrainskim",
        "tlumaczenie na jezyk ukrainski",
        "subtitles by the amaraorg community",
    ]

    /// Progi zmyślenia — te same liczby co u Filipa.
    static let noSpeechThreshold: Float = 0.3
    static let logProbabilityThreshold: Float = -0.6

    /// Zwraca segmenty bez zmyślonego ogona.
    static func dropTrailingHallucinations(_ segments: [Segment]) -> [Segment] {
        var kept = segments
        while let last = kept.last {
            guard farewells.contains(normalize(last.text)) else { break }
            let suspicious = last.noSpeechProbability >= noSpeechThreshold
                || last.averageLogProbability <= logProbabilityThreshold
            guard suspicious else { break }
            kept.removeLast()
        }
        return kept
    }

    /// Cały tekst to jedno zmyślone pożegnanie? Wtedy nie ma czego wstawiać.
    /// Osobna ścieżka, bo przy `single_segment` (podgląd na żywo, tryb nasłuchu)
    /// segment jest tylko jeden i pętla wyżej zostawiłaby pustą listę.
    static func isPureHallucination(_ text: String, noSpeechProbability: Float, averageLogProbability: Float) -> Bool {
        guard farewells.contains(normalize(text)) else { return false }
        return noSpeechProbability >= noSpeechThreshold || averageLogProbability <= logProbabilityThreshold
    }

    /// Małe litery, bez interpunkcji, bez diakrytyków. „ł" trzeba zdjąć ręcznie
    /// — to osobny znak Unicode, a nie „l" z kreską, więc `folding` go nie rusza
    /// (ta sama landmina co w `VoiceCommandRouter.normalize`).
    static func normalize(_ text: String) -> String {
        let deStroked = text
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ł", with: "L")
        let folded = deStroked.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "pl_PL")
        )
        let cleaned = folded.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
        return String(cleaned).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
