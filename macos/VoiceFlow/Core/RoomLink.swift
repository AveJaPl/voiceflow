import Foundation

/// Kabel pod `RoomClient`: WebSocket, ponawianie i puls.
///
/// Trzymany osobno od `RoomClient` z tego samego powodu co po stronie Pythona:
/// tam mieszkają reguły i są testowalne bez sieci, a tutaj wszystko, co potrafi
/// się zepsuć przez łącze. Ten plik niczego nie rozstrzyga.
///
/// Używa `URLSessionWebSocketTask` z Foundation — zero zależności zewnętrznych,
/// w przeciwieństwie do strony pythonowej, gdzie doszedł pakiet `websockets`.
final class RoomLink: NSObject, RoomTransport, @unchecked Sendable {

    /// Zgodnie z serwerem: mówiący bez pulsu przez 10 s jest uznany za takiego,
    /// który skończył. Pulsujemy częściej, żeby nie ocierać się o granicę.
    private static let heartbeatSeconds: TimeInterval = 3
    /// Rośnie, potem przestaje. Pokój, który wraca po godzinie, ma zostać
    /// odzyskany w ciągu minuty, a nie następnej godziny.
    private static let reconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30, 60]

    private let config: RoomConfiguration
    private let onDisconnected: () -> Void
    private var onMessageCallback: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "io.github.avejapl.voiceflow.room")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: DispatchSourceTimer?
    private var attempt = 0
    private var stopped = false

    init(config: RoomConfiguration, onDisconnected: @escaping () -> Void) {
        self.config = config
        self.onDisconnected = onDisconnected
        super.init()
    }

    // MARK: - RoomTransport

    func send(_ payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        queue.async { [weak self] in
            self?.task?.send(.string(text)) { _ in
                // Zgłaszanie jest best-effort: dyktowanie już się odbyło
                // lokalnie i jego wynik jest u użytkownika niezależnie od tego,
                // czy statystyka doleciała.
            }
        }
    }

    func onMessage(_ callback: @escaping ([String: Any]) -> Void) {
        queue.async { [weak self] in self?.onMessageCallback = callback }
    }

    // MARK: - Lifecycle

    func start() {
        guard config.isUsable else { return }
        queue.async { [weak self] in
            guard let self, self.session == nil else { return }
            self.stopped = false
            self.session = URLSession(configuration: .default)
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    // MARK: - Plumbing (wyłącznie na `queue`)

    private func url() -> URL? {
        var base = config.server
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/ws?room=\(config.code)&token=\(config.token)")
    }

    private func connect() {
        // `let url` (skrót od `let url = url`) NIE działa: `url` to metoda
        // `() -> URL?`, więc skrót próbuje rozpakować samą funkcję, nie jej wynik.
        // Wywołanie musi być jawne.
        guard !stopped, let url = url(), let session else { return }
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        startHeartbeat()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    self.deliver(message)
                    self.attempt = 0
                    self.receive()
                case .failure:
                    self.dropAndRetry()
                }
            }
        }
    }

    private func deliver(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }  // śmieć w kanale nie zrywa połączenia
        onMessageCallback?(payload)
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatSeconds, repeating: Self.heartbeatSeconds)
        timer.setEventHandler { [weak self] in
            self?.send(["type": "heartbeat"])
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func dropAndRetry() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        task = nil
        // Bez tego blokada nałożona przez cudze dyktowanie zostałaby z nami po
        // zerwaniu łącza — a wtedy awaria sieci odbiera użytkownikowi
        // podstawową funkcję narzędzia.
        onDisconnected()
        guard !stopped else { return }
        let delay = Self.reconnectDelays[min(attempt, Self.reconnectDelays.count - 1)]
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}
