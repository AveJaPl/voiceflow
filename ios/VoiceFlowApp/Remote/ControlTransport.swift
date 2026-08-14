import Foundation
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "Transport")

/// Stan połączenia z Makiem, w postaci, którą da się pokazać człowiekowi.
/// `waiting` niesie sekundy do kolejnej próby — ekran, który mówi „ponawiam za
/// 4 s", jest czymś zupełnie innym niż ekran, który po prostu wisi.
enum TransportState: Equatable {
    case idle
    case connecting
    case connected
    case waiting(retryIn: TimeInterval)
    case failed(String)
}

/// Kanał sterujący do Maca. **Protokół, nie klasa** — i to jest celowe:
/// dziś jedyną implementacją jest WebSocket przez relay, ale plan (§6) przewiduje
/// drugą, bezpośrednią po sieci lokalnej. Jeśli reszta apki gada z protokołem,
/// dołożenie LAN-u nie dotyka ani maszyny stanów, ani UI. Ten sam protokół jest
/// też punktem wpięcia atrap w testach — `RemoteSession` da się w całości
/// przetestować bez jednego gniazda sieciowego.
@MainActor
protocol ControlTransport: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onBinary: ((Data) -> Void)? { get set }
    var onState: ((TransportState) -> Void)? { get set }

    func connect()
    func disconnect()
    /// „Spróbuj TERAZ" — przerywa odczekiwanie backoffu. Wołane, gdy apka wraca
    /// na wierzch: człowiek patrzy w ekran i nie ma czekać 8 s tylko dlatego, że
    /// poprzednia próba wypadła nieszczęśliwie.
    func reconnectNow()
    func send(text: String)
    func send(binary: Data)
}

extension ControlTransport {
    func reconnectNow() {}
}

/// WebSocket przez relay (`relay/src/relayHub.js`). Rola `phone`, token z
/// parowania. Reconnect z backoffem wykładniczym mieszka TUTAJ, a nie w
/// `RemoteSession`: wyższa warstwa ma się zajmować dyktowaniem, nie topologią
/// sieci.
@MainActor
final class WebSocketTransport: ControlTransport {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onState: ((TransportState) -> Void)?

    private let urlProvider: () -> URL?
    private let session: URLSession
    private let socketDelegate = SocketDelegate()
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    /// Rozróżnia „rozłączyło się samo" (reconnect) od „user wyszedł" (koniec).
    private var wantsConnection = false
    private var backoff: TimeInterval = 1
    /// Ustawiane przez `reconnectNow()` — przerywa drzemkę między próbami.
    private var retryNow = false

    /// 8 s zamiast 30: telefon czeka na Maca w ręce użytkownika.
    private static let maxBackoff: TimeInterval = 8
    private static let pingInterval: TimeInterval = 20

    init(urlProvider: @escaping () -> URL?, session: URLSession? = nil) {
        self.urlProvider = urlProvider
        // Własna `URLSession` z delegatem, a nie `.shared`: potrzebujemy
        // `didOpenWithProtocol`, czyli momentu FAKTYCZNEGO zestawienia
        // połączenia. Patrz `connectLoop` — bez tego sygnału obie strony czekają
        // na siebie nawzajem.
        self.session = session ?? URLSession(
            configuration: .default, delegate: socketDelegate, delegateQueue: .main
        )
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func connect() {
        guard !wantsConnection else { return }
        wantsConnection = true
        backoff = 1
        loop = Task { [weak self] in await self?.connectLoop() }
    }

    func disconnect() {
        wantsConnection = false
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onState?(.idle)
    }

    func reconnectNow() {
        retryNow = true
        guard wantsConnection else { return connect() }
        // Gniazdo, które umarło po cichu (uśpiony telefon, zmiana sieci), nie
        // zgłasza błędu — ubicie go wybija pętlę odbioru z zawieszenia.
        task?.cancel(with: .abnormalClosure, reason: nil)
    }

    func send(text: String) {
        guard let task else { return }
        Task { [weak self] in
            do {
                try await task.send(.string(text))
            } catch {
                log.error("wysyłka tekstu nie powiodła się: \(error.localizedDescription)")
                self?.dropConnection()
            }
        }
    }

    func send(binary: Data) {
        guard let task else { return }
        // Audio celowo BEZ obsługi błędu z rozłączaniem: pojedyncza zgubiona
        // ramka PCM to 20 ms dźwięku, a zerwanie sesji z tego powodu kosztowałoby
        // całą wypowiedź. Zerwane połączenie i tak wykryje pętla odbioru.
        Task { try? await task.send(.data(binary)) }
    }

    private func connectLoop() async {
        while wantsConnection, !Task.isCancelled {
            guard let url = urlProvider() else {
                onState?(.failed("Brak sparowanego Maca."))
                wantsConnection = false
                return
            }

            onState?(.connecting)
            let socket = session.webSocketTask(with: url)
            task = socket
            socket.resume()

            // `connected` sygnalizuje DELEGAT (`didOpenWithProtocol`), a nie
            // pierwsza odebrana ramka.
            //
            // Pierwsza wersja czekała właśnie na ramkę — „skoro coś przyszło, to
            // na pewno działa". Zakleszczenie zobaczone na żywo 2026-08-11:
            // telefon wysyła `hello` dopiero po `connected`, a Mac odzywa się
            // dopiero po `hello`. Obie strony czekały na siebie w nieskończoność,
            // a ekran pokazywał „łączę…" i nic więcej. Testy jednostkowe tego nie
            // złapały, bo atrapa transportu z definicji nie ma uścisku dłoni.
            //
            // `resume()` też nie wystarczy: wraca natychmiast, jeszcze przed
            // handshakiem, więc „połączono" w tym miejscu byłoby kłamstwem, gdy
            // relay leży.
            socketDelegate.onOpen = { [weak self] in
                guard let self, currentSocketIsCurrent(socket) else { return }
                backoff = 1
                onState?(.connected)
            }

            let heartbeat = startHeartbeat(for: socket)
            do {
                while wantsConnection, !Task.isCancelled {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let text): onText?(text)
                    case .data(let data): onBinary?(data)
                    @unknown default: break
                    }
                }
            } catch {
                if wantsConnection {
                    log.error("połączenie przerwane: \(error.localizedDescription)")
                }
            }

            heartbeat.cancel()
            task = nil
            guard wantsConnection, !Task.isCancelled else { break }

            onState?(.waiting(retryIn: backoff))
            await sleepBeforeRetry(backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        }
    }

    /// Drzemka w kawałkach po 200 ms, żeby `reconnectNow()` mogło ją przerwać.
    /// Prostsze i mniej zawodne niż budzenie uśpionego zadania kontynuacją.
    private func sleepBeforeRetry(_ seconds: TimeInterval) async {
        retryNow = false
        var slept: TimeInterval = 0
        while slept < seconds, wantsConnection, !Task.isCancelled, !retryNow {
            try? await Task.sleep(nanoseconds: 200_000_000)
            slept += 0.2
        }
        if retryNow { backoff = 1 }
        retryNow = false
    }

    /// Puls: bez niego gniazdo po uśpieniu telefonu albo zmianie sieci umiera
    /// po cichu — `receive()` wisi, ekran pokazuje „połączony", a nic nie leci.
    private func startHeartbeat(for socket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task { [weak self, weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let socket, let self else { return }
                let alive: Bool = await withCheckedContinuation { continuation in
                    socket.sendPing { error in continuation.resume(returning: error == nil) }
                }
                guard !alive else { continue }
                log.error("puls nie doszedł — zrywam martwe połączenie")
                _ = self
                socket.cancel(with: .abnormalClosure, reason: nil)
                return
            }
        }
    }

    private func dropConnection() {
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
    }

    /// Chroni przed sygnałem otwarcia od POPRZEDNIEGO gniazda, które właśnie
    /// zostało zastąpione przy reconnekcie.
    private func currentSocketIsCurrent(_ socket: URLSessionWebSocketTask) -> Bool {
        task === socket
    }
}

/// Delegat istnieje wyłącznie po to, żeby wiedzieć, KIEDY połączenie naprawdę
/// się zestawiło. `URLSessionWebSocketTask` nie ma na to żadnego innego,
/// publicznego sygnału.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (() -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?()
    }
}
