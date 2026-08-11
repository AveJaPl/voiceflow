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
    func endUtterance()
    func feed(_ buffer: AVAudioPCMBuffer)
}
