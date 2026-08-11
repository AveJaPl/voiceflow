import Foundation

/// VAD energetyczny — wykrywa onset mowy, pauzy i koniec wypowiedzi z poziomu RMS
/// audio, bez modelu. Wystarczające do granic segmentów (§6a: "koniec segmentu =
/// kropka/akapit w pierwszym przybliżeniu") i do watchdogu rotacji w
/// AppleSpeechEngine (audio głośne, ale silnik milczy => sesja martwa).
final class Segmenter {
    struct Config {
        /// RMS powyżej którego uznajemy, że ktoś mówi (skala 0...1, po `AudioCapture.rms`).
        var speechThreshold: Float = 0.015
        /// Cisza dłuższa niż to = koniec wypowiedzi (nowy akapit).
        var endOfUtteranceSilence: TimeInterval = 0.9
        /// Cisza krótsza, ale odczuwalna = pauza wewnątrz wypowiedzi (kandydat na przecinek).
        var pauseSilence: TimeInterval = 0.35
    }

    enum Event: Equatable {
        case speechStarted
        case pause(duration: TimeInterval)
        case speechEnded(duration: TimeInterval)
    }

    private let config: Config
    private(set) var isSpeaking = false

    private var speechStartedAt: TimeInterval?
    private var lastSpeechAt: TimeInterval?
    private var pauseReported = false

    init(config: Config = Config()) {
        self.config = config
    }

    func reset() {
        isSpeaking = false
        speechStartedAt = nil
        lastSpeechAt = nil
        pauseReported = false
    }

    /// Podaj kolejną ramkę: poziom RMS i znacznik czasu (sekundy, monotoniczny —
    /// np. `CACurrentMediaTime()`). Zwraca zdarzenie, jeśli akurat nastąpiła
    /// zmiana stanu.
    func process(rms: Float, at timestamp: TimeInterval) -> Event? {
        let loud = rms >= config.speechThreshold

        if loud {
            pauseReported = false
            lastSpeechAt = timestamp
            if !isSpeaking {
                isSpeaking = true
                speechStartedAt = timestamp
                return .speechStarted
            }
            return nil
        }

        guard isSpeaking, let last = lastSpeechAt else { return nil }
        let silence = timestamp - last

        if silence >= config.endOfUtteranceSilence {
            let duration = last - (speechStartedAt ?? last)
            isSpeaking = false
            speechStartedAt = nil
            lastSpeechAt = nil
            pauseReported = false
            return .speechEnded(duration: duration)
        }

        if silence >= config.pauseSilence, !pauseReported {
            pauseReported = true
            return .pause(duration: silence)
        }

        return nil
    }
}
