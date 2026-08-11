import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "MicStreamer")

enum MicError: LocalizedError {
    case permissionDenied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Brak zgody na mikrofon. Ustawienia → VoiceFlow → Mikrofon."
        case .unavailable(let why): "Mikrofon niedostępny: \(why)"
        }
    }
}

/// Źródło dźwięku dla zdalnej wypowiedzi. Protokół, żeby `RemoteSession` dało się
/// przetestować bez mikrofonu, bez uprawnień i bez symulatora audio.
@MainActor
protocol MicStreaming: AnyObject {
    /// Wołane z gotowymi porcjami PCM (Int16 LE, mono, 16 kHz) — zawsze na głównym wątku.
    var onChunk: ((Data) -> Void)? { get set }

    /// Otwiera mikrofon i zaczyna BUFOROWAĆ. Nic jeszcze nie wychodzi na sieć.
    func startBuffering() async throws

    /// Mac potwierdził `started` — wypycha bufor i przechodzi w tryb strumienia.
    func flushAndStream()

    /// Koniec albo błąd. Zatrzymuje mikrofon; niewypchnięty bufor przepada.
    func stop()
}

/// Nagrywa i strumieniuje PCM do Maca.
///
/// SEDNO TEJ KLASY TO BUFOR (plan §4.5). Telefon otwiera mikrofon w momencie
/// dotknięcia ekranu, ale nie wolno mu wysłać ani jednej próbki, dopóki Mac nie
/// odpowie `started` — bo dopóki nie odpowiedział, nie wiadomo nawet, czy
/// właściwe okno jest na froncie. Round-trip przez relay to 60–150 ms, czyli
/// dokładnie tyle, ile trwa pierwsze słowo. Bez bufora każde zdanie zaczynałoby
/// się od uciętej sylaby; z buforem nie ginie nic, a jeśli Mac odpowie błędem,
/// bufor po prostu przepada i na sieć nie poszło nic.
@MainActor
final class MicStreamer: MicStreaming {
    var onChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isTapped = false

    private var prebuffer = Prebuffer()
    private var isStreaming = false

    private static let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Wire.audioSampleRate,
        channels: Wire.audioChannels,
        interleaved: true
    )!

    // MARK: - MicStreaming

    func startBuffering() async throws {
        guard await Self.ensurePermission() else { throw MicError.permissionDenied }

        prebuffer.discard()
        isStreaming = false

        let session = AVAudioSession.sharedInstance()
        do {
            // `.record` + `.measurement`: bez przetwarzania sygnału pod rozmowy
            // (AGC/redukcja szumów), które psuje wynik rozpoznawania mowy.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw MicError.unavailable(error.localizedDescription)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MicError.unavailable("wejście audio zwróciło format zerowy")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.wireFormat) else {
            throw MicError.unavailable("nie udało się utworzyć konwertera \(inputFormat.sampleRate) Hz → 16 kHz")
        }
        self.converter = converter

        if isTapped {
            input.removeTap(onBus: 0)
            isTapped = false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Blok taps biegnie na wątku audio — konwersja tu, a dopiero gotowe
            // bajty przechodzą na główny wątek. Odwrotna kolejność (hop na main
            // z każdym surowym buforem) zapycha główny wątek przy 48 kHz.
            guard let data = Self.convert(buffer, using: converter, to: Self.wireFormat) else { return }
            Task { @MainActor [weak self] in self?.emit(data) }
        }
        isTapped = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw MicError.unavailable(error.localizedDescription)
        }
        log.info("mikrofon otwarty, buforuję do potwierdzenia z Maca")
    }

    func flushAndStream() {
        isStreaming = true
        let buffered = prebuffer.drain()
        guard !buffered.isEmpty else { return }
        log.info("wypycham bufor przedstartowy: \(buffered.count) B")
        onChunk?(buffered)
    }

    func stop() {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning { engine.stop() }
        converter = nil
        prebuffer.discard()
        isStreaming = false
        // Zwalniamy sesję audio: bez tego lokalne dyktowanie w zakładce „Dyktuj"
        // (`ContainerDictationEngine`) dostaje zajęte wejście i cicho nie działa.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Wewnętrzne

    private func emit(_ data: Data) {
        if isStreaming {
            onChunk?(data)
            return
        }
        prebuffer.append(data)
    }

    private static func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }

    /// Konwersja dowolnego formatu wejściowego (zwykle 48 kHz float32 stereo) na
    /// format drutu. `nil` przy błędzie — pojedyncza zgubiona porcja jest
    /// nieszkodliwa, a rzucanie wyjątkami z wątku audio nie jest.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> Data? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("konwersja PCM nie powiodła się: \(error.localizedDescription)")
            return nil
        }
        guard output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// Bufor przedstartowy: dźwięk nagrany, zanim Mac potwierdził `started`.
///
/// Wydzielony jako czysta struktura, bo to jest mechanizm „nie gub pierwszego
/// słowa" i chcę go testować bez otwierania mikrofonu. Limit jest twardy: gdyby
/// Mac nigdy nie odpowiedział, bufor bez ograniczenia rósłby w nieskończoność —
/// a i tak nie ma sensu trzymać więcej, niż wynosi najgorszy realny round-trip.
struct Prebuffer {
    /// 2 s przy 16 kHz Int16 mono. Realny round-trip to 60–150 ms, więc to
    /// dwudziestokrotny zapas — na tyle duży, żeby nie ucinał, i na tyle mały,
    /// żeby nic nie zjadał.
    static let maxBytes = Int(Wire.audioSampleRate) * MemoryLayout<Int16>.size * 2

    private(set) var data = Data()

    var count: Int { data.count }
    var isEmpty: Bool { data.isEmpty }

    /// Po przekroczeniu limitu wypada NAJSTARSZY dźwięk, nie najnowszy — gdy
    /// czekanie się przeciąga, chcemy końcówkę wypowiedzi, nie jej początek
    /// sprzed trzech sekund.
    mutating func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > Self.maxBytes {
            data.removeFirst(data.count - Self.maxBytes)
        }
    }

    mutating func drain() -> Data {
        defer { data.removeAll(keepingCapacity: true) }
        return data
    }

    mutating func discard() {
        data.removeAll(keepingCapacity: false)
    }
}
