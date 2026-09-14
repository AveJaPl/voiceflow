import Foundation
import Network
import os.log

/// „Udostępnij silnik w sieci lokalnej” — Mac wystawia swój whisper (Metal)
/// pod tym samym kontraktem co `server/` (`TranscriptionWire`), żeby iPhone
/// albo słabszy komputer w tej samej sieci liczył tutaj zamiast u siebie.
/// Ogłasza się przez Bonjour (`_voiceflow-asr._tcp`), więc telefon widzi
/// Maca na liście bez wpisywania adresu.
///
/// Minimalny HTTP na `NWListener`: jeden endpoint, multipart w całości w
/// pamięci (kilka MB na 5 minut mowy), odpowiedź JSON. Bez TLS — to jest
/// sieć lokalna, a nagranie i tak wraca jako tekst do nadawcy. Domyślnie
/// WYŁĄCZONE; włącza się w Zaawansowanych.
@MainActor
final class EngineShareServer {
    private let log = Logger(subsystem: "pl.programo.voiceflow", category: "EngineShare")
    private var listener: NWListener?
    private let transcribe: (_ samples: [Float], _ prompt: String) async -> String
    private(set) var port: UInt16 = TranscriptionWire.defaultPort
    private(set) var isRunning = false

    init(transcribe: @escaping (_ samples: [Float], _ prompt: String) async -> String) {
        self.transcribe = transcribe
    }

    func start() {
        start(advertise: true)
    }

    /// `advertise: false` = sam HTTP bez Bonjour. Tak kończy się start, gdy
    /// system odmówi rejestracji usługi (błąd -65555 NoAuth — brak zgody na
    /// sieć lokalną albo proces bez `NSBonjourServices`, np. xctest): lepiej
    /// słuchać pod adresem wpisanym ręcznie, niż nie słuchać wcale.
    private func start(advertise: Bool) {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            if advertise {
                listener.service = NWListener.Service(
                    name: Host.current().localizedName ?? "Mac",
                    type: TranscriptionWire.bonjourType
                )
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        DebugLog.write("EngineShare", "słucham na :\(self.port)\(advertise ? ", Bonjour \(TranscriptionWire.bonjourType)" : ", bez Bonjour")")
                    case .failed(let error):
                        self.isRunning = false
                        DebugLog.write("EngineShare", "błąd nasłuchu: \(error.localizedDescription)")
                        if advertise {
                            self.listener?.cancel()
                            self.listener = nil
                            self.start(advertise: false)
                        }
                    case .cancelled:
                        self.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            DebugLog.write("EngineShare", "nie mogę uruchomić nasłuchu: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data())
    }

    /// Czyta nagłówki, potem dokładnie `Content-Length` bajtów ciała.
    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                let contentLength = Self.header("content-length", in: headerText).flatMap(Int.init) ?? 0
                let body = buffer[headerEnd.upperBound...]
                if body.count >= contentLength {
                    Task { @MainActor in
                        await self.respond(connection, headers: headerText, body: Data(body.prefix(contentLength)))
                    }
                    return
                }
            }
            if isComplete { connection.cancel(); return }
            self.receiveRequest(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, headers: String, body: Data) async {
        let requestLine = headers.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        if method == "GET", path == "/health" {
            send(connection, status: 200, json: Data("{\"status\":\"ok\",\"service\":\"voiceflow-mac\"}".utf8))
            return
        }
        guard method == "POST", path.hasPrefix(TranscriptionWire.path) else {
            send(connection, status: 404, json: Data("{\"error\":\"not_found\"}".utf8))
            return
        }
        guard let contentType = Self.header("content-type", in: headers),
              let boundaryRange = contentType.range(of: "boundary=") else {
            send(connection, status: 400, json: Data("{\"error\":\"multipart_required\"}".utf8))
            return
        }
        let boundary = String(contentType[boundaryRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parsed = TranscriptionWire.parseMultipart(body: body, boundary: boundary)
        guard let file = parsed.file, let wav = TranscriptionWire.samples(fromWAV: file) else {
            send(connection, status: 400, json: Data("{\"error\":\"wav_required\"}".utf8))
            return
        }
        let samples = TranscriptionWire.resampleLinear(wav.samples, from: wav.sampleRate, to: 16_000)
        let started = Date()
        let text = await transcribe(samples, parsed.fields["prompt"] ?? "")
        DebugLog.write("EngineShare", String(format: "policzone dla klienta: %.2f s audio → %.2f s", Double(samples.count) / 16_000, Date().timeIntervalSince(started)))
        send(connection, status: 200, json: TranscriptionWire.responseJSON(text: text))
    }

    private func send(_ connection: NWConnection, status: Int, json: Data) {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func header(_ name: String, in headers: String) -> String? {
        for line in headers.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
