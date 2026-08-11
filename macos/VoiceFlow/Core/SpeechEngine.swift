import AVFoundation

/// Warstwy tekstu opisane w docs/plans/mvp-streaming-dictation.md §6.
/// `volatile` może się jeszcze zmienić wstecz, `committed` jest zamrożone
/// po ustabilizowaniu segmentu, `finalized` to tekst po Formatterze na koniec wypowiedzi.
enum TranscriptUpdate {
    case volatile(String)
    case committed(String)
    case finalized(String)
}

/// Kontrakt między Core a resztą aplikacji — patrz docs/plans/mac-mvp-implementation.md.
///
/// `prewarm()` jest wołane RAZ, przy starcie aplikacji. Tworzy trwałą sesję ASR
/// (żądanie + task rozpoznawania), zanim jest jakiekolwiek audio. To jest dźwignia
/// zmierzona w §5d: 886 ms → 83 ms do pierwszego partiala, bo skrót nie płaci
/// kosztu utworzenia sesji.
///
/// `beginUtterance()` / `endUtterance()` TYLKO odkręcają i zakręcają kurek audio —
/// nigdy nie tworzą ani nie niszczą sesji rozpoznawania.
protocol SpeechEngine: AnyObject {
    var updates: AsyncStream<TranscriptUpdate> { get }
    func prewarm() async throws
    func beginUtterance()

    /// Kończy wypowiedź i zwraca TEKST KOŃCOWY, jeśli silnik potrafi zrobić lepszy
    /// niż to, co narosło w strumieniu.
    ///
    /// Dlaczego `async` i dlaczego coś zwraca: wcześniej ta metoda tylko zlecała
    /// pracę i wracała natychmiast, a `SessionController` czytał `differ.displayedText`
    /// w następnej linijce — czyli ZANIM silnik zdążył zdekodować końcówkę. Ostatnie
    /// słowa wypowiedzi systematycznie ginęły, a test end-to-end maskował to
    /// `sleep`em 700 ms wpisanym na sztywno.
    ///
    /// `nil` znaczy „nie mam nic lepszego, użyj tekstu ze strumienia" — tak
    /// odpowiada `AppleSpeechEngine`, który nie ma osobnego przebiegu końcowego.
    func endUtterance() async -> String?

    /// Porzucenie wypowiedzi (Escape). Silnik ma zapomnieć audio i NIE emitować
    /// już żadnych aktualizacji — inaczej ostatnie zdekodowane okno dolatuje po
    /// anulowaniu i dokleja się do następnej wypowiedzi.
    func cancelUtterance()

    func feed(_ buffer: AVAudioPCMBuffer)
}
