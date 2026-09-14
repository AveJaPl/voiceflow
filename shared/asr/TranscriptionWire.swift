import Foundation

/// Kontrakt „własnego serwera transkrypcji” — ten sam plik kompilują apki na
/// Macu i iPhonie, a `server/README.md` opisuje go dla ludzi. Zgodny z
/// OpenAI: `POST <baza>/v1/audio/transcriptions`, multipart z polami `file`
/// (WAV 16 kHz mono), `language`, `prompt`, `response_format=json`;
/// odpowiedź `{"text": "..."}`. Dzięki temu pod jedno pole w Ustawieniach
/// podłącza się whisper-server z whisper.cpp, faster-whisper-server, Speaches
/// i płatne API — bez osobnego kodu na każdy.
enum TranscriptionWire {
    static let path = "/v1/audio/transcriptions"
    /// Bonjour: Mac, który udostępnia swój silnik w sieci lokalnej.
    static let bonjourType = "_voiceflow-asr._tcp"
    static let defaultPort: UInt16 = 8090

    // MARK: - WAV 16 kHz mono, 16-bit PCM

    /// Próbki Float32 (−1…1) → plik WAV 16-bit. 16 kHz mono to format, który
    /// każdy silnik whisper przyjmuje bez konwersji po drugiej stronie.
    static func wavData(samples: [Float], sampleRate: UInt32 = 16_000) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// Odczyt WAV PCM 16-bit (mono lub stereo — stereo uśredniane). Zwraca
    /// próbki i częstotliwość; przepróbkowanie zostawia wołającemu.
    static func samples(fromWAV data: Data) -> (samples: [Float], sampleRate: Int)? {
        guard data.count > 44, String(decoding: data[0..<4], as: UTF8.self) == "RIFF" else { return nil }
        var offset = 12
        var channels = 1
        var sampleRate = 16_000
        var bits = 16
        var pcm: Data?
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            let body = offset + 8
            if id == "fmt ", body + 16 <= data.count {
                channels = Int(data[body + 2..<body + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
                sampleRate = Int(data[body + 4..<body + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                bits = Int(data[body + 14..<body + 16].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
            } else if id == "data" {
                pcm = data[body..<min(body + size, data.count)]
                break
            }
            offset = body + size + (size % 2)
        }
        guard let pcm, bits == 16, channels >= 1 else { return nil }
        let frameCount = pcm.count / (2 * channels)
        var out = [Float](repeating: 0, count: frameCount)
        pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(Int16(littleEndian: ints[frame * channels + channel])) }
                out[frame] = sum / Float(channels) / Float(Int16.max)
            }
        }
        return (out, sampleRate)
    }

    /// Najprostsze przepróbkowanie liniowe — wystarcza do mowy, gdy serwer
    /// dostanie 44,1/48 kHz od klienta, który nie umie inaczej.
    static func resampleLinear(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
        guard source != target, source > 0, !samples.isEmpty else { return samples }
        let ratio = Double(source) / Double(target)
        let count = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let position = Double(index) * ratio
            let left = Int(position)
            let right = min(left + 1, samples.count - 1)
            let fraction = Float(position - Double(left))
            out[index] = samples[left] * (1 - fraction) + samples[right] * fraction
        }
        return out
    }

    // MARK: - Multipart

    static func multipartBody(boundary: String, wav: Data, language: String, prompt: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(contentsOf: Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("language", language)
        field("response_format", "json")
        field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(contentsOf: Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(contentsOf: Array("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Parser multipartu po stronie serwera w apce (Mac udostępniający silnik).
    /// Zwraca pola tekstowe i zawartość `file`. Celowo bez obsługi zagnieżdżeń
    /// i kodowań — klienci to nasze apki i `curl`.
    static func parseMultipart(body: Data, boundary: String) -> (fields: [String: String], file: Data?) {
        let delimiter = Data("--\(boundary)".utf8)
        var fields: [String: String] = [:]
        var file: Data?
        var cursor = body.startIndex
        while let range = body.range(of: delimiter, in: cursor..<body.endIndex) {
            let partStart = range.upperBound
            guard partStart + 2 <= body.endIndex else { break }
            if body[partStart..<partStart + 2] == Data("--".utf8) { break }
            guard let next = body.range(of: delimiter, in: partStart..<body.endIndex) else { break }
            let part = body[partStart..<next.lowerBound]
            cursor = next.lowerBound
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headers = String(decoding: part[part.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var content = part[headerEnd.upperBound..<part.endIndex]
            if content.suffix(2) == Data("\r\n".utf8) { content = content.dropLast(2) }
            guard let nameRange = headers.range(of: "name=\"") else { continue }
            let name = headers[nameRange.upperBound...].prefix { $0 != "\"" }
            if name == "file" {
                file = Data(content)
            } else {
                fields[String(name)] = String(decoding: content, as: UTF8.self)
            }
        }
        return (fields, file)
    }

    /// `{"text": "..."}` — zarówno OpenAI, jak i whisper-server.
    static func text(fromResponse data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["text"] as? String
    }

    static func responseJSON(text: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["text": text])) ?? Data("{\"text\":\"\"}".utf8)
    }

    /// Adres serwera z ustawień → URL końcówki. Przyjmuje bazę (`http://mac:8090`)
    /// albo pełną ścieżkę (`https://api.openai.com/v1/audio/transcriptions`).
    static func endpoint(from raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.hasPrefix("http://"), !base.hasPrefix("https://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix(path) { return URL(string: base) }
        if base.hasSuffix("/v1") { return URL(string: base + "/audio/transcriptions") }
        return URL(string: base + path)
    }
}
