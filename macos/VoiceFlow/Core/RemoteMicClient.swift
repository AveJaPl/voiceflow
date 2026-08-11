import AVFoundation
import AppKit
import Foundation
import os.log

/// Zdalny mikrofon (telefon) — `docs/plans/remote-mic-relay.md`. Trwałe
/// WYCHODZĄCE połączenie WebSocket do relaya (`services/relay/`, już
/// zmergowany i zweryfikowany osobno). Telefon (osobna, LEKKA apka iOS, poza
/// zakresem TEGO zadania) nagrywa i strumieniuje audio; ten klient tłumaczy
/// zdarzenia z sieci na DOKŁADNIE te same wywołania, którymi dziś steruje
/// `HotkeyMonitor` (`SessionController.beginUtterance()/endUtterance()`) —
/// zero duplikacji pipeline'u ASR/Formatter/TextInjector (§4 planu).
///
/// Kontrakt ramek na WS (dokumentowany tu, bo apka iOS to osobne zadanie —
/// implementator telefonu MUSI się tego trzymać):
/// - Tekstowe ramki JSON OD telefonu: `{"type":"start"}` (naciśnięcie
///   przycisku — początek wypowiedzi), `{"type":"end"}` (puszczenie —
///   koniec), `{"type":"requestFocus"}` (telefon chce natychmiast dostać
///   bieżący focus, np. przy otwarciu ekranu, bez czekania na kolejną zmianę).
/// - Ramki binarne OD telefonu: surowe próbki PCM, **Int16 little-endian,
///   mono, 16000 Hz**, wysyłane WYŁĄCZNIE między `start` i `end` — poza tym
///   oknem są ignorowane (`isRemoteUtteranceActive`).
/// - Tekstowe ramki JSON OD Maca: `{"type":"focus","app":"...","window":
///   "..."}` (§5a planu) — przy zmianie focusu (`NSWorkspace
///   .didActivateApplicationNotification`) ORAZ w odpowiedzi na `start`/
///   `requestFocus`, żeby UI telefonu od razu miało aktualny stan.
///
/// Współistnienie z lokalnym skrótem (kryterium #4 zadania): `AudioCapture`
/// jest DZIELONE z `SessionController` skrótu lokalnego (ta sama instancja,
/// wstrzyknięta z `VoiceFlowApp`). `startOverride`/`stopOverride` (mechanizm
/// z `AudioCapture`, ten sam co w testach whisper — patrz jego doc-comment)
/// są ustawiane TYLKO na czas trwania jednej zdalnej wypowiedzi (między
/// `beginRemoteUtterance()` i `endRemoteUtterance()`) i zaraz potem czyszczone
/// — poza tym oknem `AudioCapture.start()` normalnie otwiera prawdziwy
/// mikrofon, więc skrót lokalny nie traci nic ze swojego zachowania. Obie
/// ścieżki dzielą jeden `SessionController` (jedna sesja dyktowania na raz —
/// `state == .idle || .done` w `beginUtterance()`/tu poniżej — to nie jest
/// osłabienie, `SessionController` z natury obsługuje jedną wypowiedź
/// naraz niezależnie od źródła audio), więc próba zdalnego startu w trakcie
/// lokalnego dyktowania (i odwrotnie) jest cicho ignorowana zamiast psuć
/// trwający pipeline.
@MainActor
final class RemoteMicClient: ObservableObject {
    enum ConnectionState: Equatable {
        case disabled
        case connecting
        case connected
        case disconnected
    }

    private let log = Logger(subsystem: "pl.programo.voiceflow", category: "RemoteMicClient")

    private let sessionController: SessionController
    private let audioCapture: AudioCapture
    private let focusProbe: FocusProbe
    private let tokenStore: PairingTokenStoring
    private let defaults: UserDefaults
    private let socketFactory: (URL) -> RemoteMicSocket

    @Published private(set) var connectionState: ConnectionState = .disabled

    private var connectionTask: Task<Void, Never>?
    private var currentSocket: RemoteMicSocket?
    private var focusObserver: NSObjectProtocol?
    private var isRemoteUtteranceActive = false

    /// Format wire dla audio od telefonu — patrz doc-comment pliku. Mono
    /// 16 kHz Int16 pasuje wprost do wymagań `WhisperSpeechEngine`
    /// (resampluje i tak przez `AVAudioConverter`, więc to praktycznie
    /// no-op) i jest standardowym, tanim formatem do strumieniowania mowy
    /// przez sieć komórkową.
    static let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!

    init(
        sessionController: SessionController,
        audioCapture: AudioCapture,
        focusProbe: FocusProbe = FocusProbe(),
        tokenStore: PairingTokenStoring = KeychainPairingTokenStore(),
        defaults: UserDefaults = .standard,
        socketFactory: @escaping (URL) -> RemoteMicSocket = { URLSession.shared.webSocketTask(with: $0) }
    ) {
        self.sessionController = sessionController
        self.audioCapture = audioCapture
        self.focusProbe = focusProbe
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.socketFactory = socketFactory
    }

    // MARK: - Cykl życia

    /// Łączy z relayem, jeśli funkcja jest włączona w Ustawieniach
    /// (`SettingsKeys.remoteMicEnabled`, domyślnie WYŁĄCZONE — nowa,
    /// niesprawdzona ścieżka sieciowa). No-op, jeśli już połączony/łączący się.
    func start() {
        guard defaults.bool(forKey: SettingsKeys.remoteMicEnabled) else {
            connectionState = .disabled
            return
        }
        guard connectionTask == nil else { return }
        connectionState = .connecting
        installFocusObserver()
        connectionTask = Task { [weak self] in
            await self?.connectLoop()
        }
    }

    func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        currentSocket?.cancel(with: .goingAway, reason: nil)
        currentSocket = nil
        removeFocusObserver()
        cancelStrandedUtteranceIfNeeded()
        connectionState = .disabled
    }

    /// Wołane po zmianie ustawień (włącz/wyłącz, host) — rozłącza i, jeśli
    /// wciąż włączone, łączy od nowa z aktualnymi wartościami.
    func restart() {
        stop()
        start()
    }

    // MARK: - Połączenie

    private func connectLoop() async {
        var backoff: TimeInterval = 1
        while !Task.isCancelled {
            guard let token = tokenStore.loadToken(), !token.isEmpty else {
                DebugLog.write("RemoteMic", "brak tokenu parowania — nie łączę, sparuj w Ustawieniach")
                connectionState = .disconnected
                return
            }
            let host = defaults.string(forKey: SettingsKeys.remoteMicHost) ?? ""
            guard let url = Self.relayURL(from: host, token: token) else {
                DebugLog.write("RemoteMic", "nieprawidłowy adres relaya: \"\(host)\"")
                log.error("Nieprawidłowy adres relaya")
                connectionState = .disconnected
                return
            }

            let socket = socketFactory(url)
            socket.resume()
            currentSocket = socket
            connectionState = .connected
            DebugLog.write("RemoteMic", "połączono z relayem")
            backoff = 1

            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    handle(message)
                }
            } catch {
                DebugLog.write("RemoteMic", "połączenie WS przerwane: \(error.localizedDescription)")
            }

            currentSocket = nil
            cancelStrandedUtteranceIfNeeded()
            connectionState = .disconnected

            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 30)
        }
    }

    /// Bazowy adres relaya akceptuje zarówno pełny URL ze schematem
    /// (`wss://…` produkcyjnie, `ws://127.0.0.1:port` do testu lokalnego —
    /// patrz kryterium #3 zadania), jak i sam host (domyślnie `wss://`).
    static func relayURL(from rawBase: String, token: String) -> URL? {
        let trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = (trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://"))
            ? trimmed : "wss://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else { return nil }
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "mac"),
            URLQueryItem(name: "token", value: token),
        ]
        return components.url
    }

    // MARK: - Tłumaczenie ramek

    func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleControlFrame(text)
        case .data(let data):
            handleAudioFrame(data)
        @unknown default:
            DebugLog.write("RemoteMic", "nieznany typ ramki WS")
        }
    }

    private func handleControlFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(ControlFrame.self, from: data) else {
            DebugLog.write("RemoteMic", "ramka tekstowa nie do sparsowania: \(text)")
            return
        }
        switch frame.type {
        case "start":
            beginRemoteUtterance()
            sendFocus()
        case "end":
            endRemoteUtterance()
        case "requestFocus":
            sendFocus()
        default:
            DebugLog.write("RemoteMic", "nieobsłużony typ ramki tekstowej: \(frame.type)")
        }
    }

    private func handleAudioFrame(_ data: Data) {
        guard isRemoteUtteranceActive else {
            DebugLog.write("RemoteMic", "ramka audio poza start/end — zignorowana")
            return
        }
        guard let buffer = Self.pcmBuffer(from: data, format: Self.wireFormat) else {
            DebugLog.write("RemoteMic", "ramka audio nie do sparsowania (\(data.count) B)")
            return
        }
        let time = AVAudioTime(hostTime: mach_absolute_time())
        audioCapture.onBuffer?(buffer, time)
        audioCapture.onLevel?(Self.rms(of: buffer), 0)
    }

    private func beginRemoteUtterance() {
        guard sessionController.state == .idle || sessionController.state == .done else {
            DebugLog.write("RemoteMic", "start zignorowany — sesja zajęta (\(sessionController.state))")
            return
        }
        // Patrz doc-comment klasy: override TYLKO na czas tej wypowiedzi, żeby
        // lokalny skrót (dzielący tę samą instancję `AudioCapture`) dalej
        // otwierał prawdziwy mikrofon poza tym oknem.
        audioCapture.startOverride = {}
        audioCapture.stopOverride = {}
        isRemoteUtteranceActive = true
        sessionController.beginUtterance()
        DebugLog.write("RemoteMic", "beginUtterance (zdalny mikrofon)")
    }

    private func endRemoteUtterance() {
        guard isRemoteUtteranceActive else { return }
        isRemoteUtteranceActive = false
        sessionController.endUtterance()
        audioCapture.startOverride = nil
        audioCapture.stopOverride = nil
        DebugLog.write("RemoteMic", "endUtterance (zdalny mikrofon)")
    }

    /// Połączenie zerwane w trakcie zdalnej wypowiedzi — anulujemy zamiast
    /// wstrzykiwać niekompletny tekst, i ZAWSZE czyścimy override, inaczej
    /// lokalny skrót zostaje uwięziony na atrapie mikrofonu do restartu apki.
    private func cancelStrandedUtteranceIfNeeded() {
        guard isRemoteUtteranceActive else { return }
        DebugLog.write("RemoteMic", "połączenie zerwane w trakcie dyktowania — anuluję sesję")
        isRemoteUtteranceActive = false
        sessionController.cancelUtterance()
        audioCapture.startOverride = nil
        audioCapture.stopOverride = nil
    }

    // MARK: - Podgląd focusu (§5a planu)

    private func installFocusObserver() {
        guard focusObserver == nil else { return }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendFocus()
        }
    }

    private func removeFocusObserver() {
        if let focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    private func sendFocus() {
        guard let socket = currentSocket else { return }
        let focus = focusProbe.currentFocusDescription()
        let frame = FocusFrame(app: focus.appName, window: focus.windowTitle)
        guard let data = try? JSONEncoder().encode(frame),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { [weak socket] in
            try? await socket?.send(.string(text))
        }
    }

    // MARK: - PCM

    static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, !data.isEmpty, data.count % bytesPerFrame == 0 else { return nil }
        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress {
                channelData[0].update(from: base, count: Int(frameCount))
            }
        }
        return buffer
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.int16ChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameCount {
            let normalized = Float(channelData[0][i]) / Float(Int16.max)
            sum += normalized * normalized
        }
        return sqrt(sum / Float(frameCount))
    }
}

private struct ControlFrame: Decodable {
    let type: String
}

private struct FocusFrame: Encodable {
    let type = "focus"
    let app: String?
    let window: String?
}

// MARK: - Socket, testowalnie

/// Cienka warstwa nad `URLSessionWebSocketTask` — pozwala testom
/// jednostkowym `RemoteMicClient` podstawić atrapę zamiast prawdziwej sieci
/// (kryterium zadania: "mockuj WebSocket, nie łącz się z prawdziwym relayem
/// w testach jednostkowych"). `URLSessionWebSocketTask` ma już DOKŁADNIE te
/// sygnatury (async `send`/`receive` od macOS 12), więc konformacja niżej nie
/// wymaga żadnego dodatkowego kodu.
protocol RemoteMicSocket: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: RemoteMicSocket {}

// MARK: - Token parowania (Keychain — NIE UserDefaults, §3 planu: to sekret)

protocol PairingTokenStoring {
    func loadToken() -> String?
    func saveToken(_ token: String)
    func clearToken()
}

/// Token z `POST /pair` (`services/relay/README.md`) trzymany w Keychain.
/// UserDefaults to zwykły plist na dysku bez szyfrowania — nieodpowiednie dla
/// czegoś, co pozwala zdalnie wstrzykiwać tekst do dowolnego okna na Macu.
final class KeychainPairingTokenStore: PairingTokenStoring {
    private let service = "pl.programo.voiceflow.remoteMicToken"
    private let account = "pairingToken"

    func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) {
        clearToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func clearToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Parowanie (POST /pair)

enum RemoteMicPairingError: LocalizedError {
    case invalidHost
    case invalidResponse
    case unauthorized
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "Adres relaya jest nieprawidłowy."
        case .invalidResponse: "Relay zwrócił nieoczekiwaną odpowiedź."
        case .unauthorized: "Zły ADMIN_SECRET (401) — sprawdź sekret z panelu Coolify."
        case .server(let code): "Relay zwrócił błąd \(code)."
        }
    }
}

/// `POST <host>/pair` z `Authorization: Bearer <adminSecret>` — patrz
/// `services/relay/README.md`. ADMIN_SECRET jest wpisywany ręcznie przez
/// Wojtka w Ustawieniach przy każdym parowaniu, NIGDY zapisywany na dysku
/// (§zadanie: "nie zaszywaj sekretu w kodzie") — tylko zwrócony token trafia
/// do Keychain (`PairingTokenStoring`).
enum RemoteMicPairing {
    static func pair(host: String, adminSecret: String) async throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemoteMicPairingError.invalidHost }
        var withScheme = trimmed
        if withScheme.hasPrefix("wss://") {
            withScheme = "https://" + withScheme.dropFirst("wss://".count)
        } else if withScheme.hasPrefix("ws://") {
            withScheme = "http://" + withScheme.dropFirst("ws://".count)
        } else if !withScheme.hasPrefix("http://"), !withScheme.hasPrefix("https://") {
            withScheme = "https://" + withScheme
        }
        guard var components = URLComponents(string: withScheme) else { throw RemoteMicPairingError.invalidHost }
        components.path = "/pair"
        guard let url = components.url else { throw RemoteMicPairingError.invalidHost }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(adminSecret)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteMicPairingError.invalidResponse }
        guard http.statusCode == 201 else {
            throw http.statusCode == 401 ? RemoteMicPairingError.unauthorized : RemoteMicPairingError.server(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw RemoteMicPairingError.invalidResponse
        }
        return token
    }
}
