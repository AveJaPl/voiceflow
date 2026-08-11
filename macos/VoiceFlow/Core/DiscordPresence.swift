import Darwin
import Foundation
import os.log

/// Discord Rich Presence — status "Dyktuje" widoczny w Discordzie przez cały
/// czas nagrania (§Zadanie 3 audytu; port `presence.enabled`/`presence
/// .client_id` z konfiguracji Linuksa). Ten sam wzorzec `start()`/`stop()` co
/// `AudioDucking`/`DiscordMuteToggling`, ale zupełnie inny mechanizm: tu nic
/// nie symulujemy klawiszami, piszemy bezpośrednio na Unix domain socket
/// Discorda protokołem IPC ("discord-rpc") — publicznym i stabilnym od lat,
/// bez dodawania zależności (biblioteki typu SwordRPC robią to samo).
protocol DiscordPresenceReporting {
    /// Łączy się z Discordem i ustawia aktywność "Dyktuje". Cicho no-op (log
    /// przez `DebugLog`, ZERO błędu widocznego dla użytkownika), jeśli
    /// wyłączone w Ustawieniach, brak client ID, Discord nie działa albo
    /// socket nie istnieje.
    func start()
    /// Czyści aktywność i zamyka połączenie. No-op, jeśli `start()` niczego
    /// nie otworzył.
    func stop()
}

/// ŚCIEŻKA SOCKETA: standardowo `$TMPDIR/discord-ipc-{0…9}` (to samo co
/// `getconf DARWIN_USER_TEMP_DIR`) — tej samej konwencji co Linux/Windows.
/// Część wariantów (starsze buildy, Discord z Mac App Store) trzymała go pod
/// `~/Library/Application Support/discord/<coś>/discord-ipc-0` — stąd druga
/// ścieżka niżej. NIE dało się zweryfikować faktycznej ścieżki na maszynie
/// budującej (sandbox agenta blokuje odczyt katalogów poza repo) — próbujemy
/// WSZYSTKICH znanych wariantów po kolei, cicho pomijamy brakujące. Do
/// zweryfikowania ręcznie przez Wojtka z uruchomionym Discordem.
final class DiscordPresence: DiscordPresenceReporting {
    private static let enabledKey = "voiceflow.discordPresenceEnabled"
    private static let clientIDKey = "voiceflow.discordPresenceClientID"

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "io.github.avejapl.voiceflow", category: "DiscordPresence")

    /// SOLO DO TESTÓW: kolejka odsłonięta (nie `private`), żeby testy mogły
    /// `queue.sync {}` zaraz po `start()`/`stop()` i sprawdzić skutek
    /// deterministycznie, bez czekania na prawdziwy zegar — ten sam powód co
    /// `AudioCapture.startOverride`.
    let queue = DispatchQueue(label: "io.github.avejapl.voiceflow.discordpresence", qos: .utility)
    /// SOLO DO TESTÓW: w środowisku testowym/CI nie ma realnego socketu
    /// Discorda pod żadną ze znanych ścieżek, więc to zawsze zostaje `nil` —
    /// dokładnie kryterium "no-op gdy brak socketu".
    private(set) var socketFD: Int32?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    private var clientID: String? {
        let value = defaults.string(forKey: Self.clientIDKey)?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty ?? true) ? nil : value
    }

    func start() {
        guard isEnabled, let clientID else {
            DebugLog.write("DiscordPresence", "start: pominięty — wyłączone albo brak client ID")
            return
        }
        queue.async { [weak self] in
            self?.connectAndSetActivity(clientID: clientID)
        }
    }

    func stop() {
        guard isEnabled, clientID != nil else { return }
        queue.async { [weak self] in
            self?.clearActivityAndDisconnect()
        }
    }

    // MARK: - IPC (WOŁANE WYŁĄCZNIE na `queue`)

    private func connectAndSetActivity(clientID: String) {
        guard let fd = Self.connectToDiscordSocket() else {
            DebugLog.write("DiscordPresence", "start: brak socketu Discorda (nie uruchomiony?) — pomijam")
            return
        }
        guard Self.sendHandshake(fd: fd, clientID: clientID) else {
            log.error("Discord IPC handshake nie powiódł się")
            DebugLog.write("DiscordPresence", "start: handshake nie powiódł się — pomijam")
            close(fd)
            return
        }
        socketFD = fd
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": [
                    "state": "Dyktuje przez VoiceFlow",
                    "details": "Rozpoznawanie mowy",
                    "timestamps": ["start": Int(Date().timeIntervalSince1970)],
                ],
            ],
            "nonce": UUID().uuidString,
        ]
        if Self.sendFrame(fd: fd, opcode: 1, json: payload) {
            log.info("Discord Rich Presence: aktywność ustawiona")
            DebugLog.write("DiscordPresence", "start: aktywność \"Dyktuje\" ustawiona")
        } else {
            DebugLog.write("DiscordPresence", "start: wysłanie SET_ACTIVITY nie powiodło się")
        }
    }

    private func clearActivityAndDisconnect() {
        guard let fd = socketFD else { return }
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": NSNull(),
            ],
            "nonce": UUID().uuidString,
        ]
        _ = Self.sendFrame(fd: fd, opcode: 1, json: payload)
        close(fd)
        socketFD = nil
        DebugLog.write("DiscordPresence", "stop: aktywność wyczyszczona, socket zamknięty")
    }

    // MARK: - Wyszukiwanie socketu — patrz doc-comment klasy o niepewności ścieżki

    private static func candidateSocketPaths() -> [String] {
        var candidates: [String] = []
        let tmp = NSTemporaryDirectory()
        for i in 0...9 {
            candidates.append(tmp + "discord-ipc-\(i)")
        }
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            let discordDir = appSupport.appendingPathComponent("discord", isDirectory: true)
            if let entries = try? FileManager.default.contentsOfDirectory(at: discordDir, includingPropertiesForKeys: nil) {
                for entry in entries {
                    for i in 0...9 {
                        candidates.append(entry.appendingPathComponent("discord-ipc-\(i)").path)
                    }
                }
            }
        }
        for i in 0...9 {
            candidates.append("/tmp/discord-ipc-\(i)")
        }
        return candidates
    }

    private static func connectToDiscordSocket() -> Int32? {
        for path in candidateSocketPaths() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                continue
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
                let buffer = rawPtr.bindMemory(to: Int8.self)
                for (i, byte) in pathBytes.enumerated() { buffer[i] = Int8(bitPattern: byte) }
                buffer[pathBytes.count] = 0
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, size)
                }
            }
            if result == 0 {
                return fd
            }
            close(fd)
        }
        return nil
    }

    // MARK: - Ramki protokołu IPC (opcode int32 LE + length int32 LE + JSON UTF8)

    private static func sendHandshake(fd: Int32, clientID: String) -> Bool {
        sendFrame(fd: fd, opcode: 0, json: ["v": 1, "client_id": clientID])
    }

    private static func sendFrame(fd: Int32, opcode: Int32, json: [String: Any]) -> Bool {
        guard let frame = encodeFrame(opcode: opcode, json: json) else { return false }
        let written = frame.withUnsafeBytes { rawPtr -> Int in
            write(fd, rawPtr.baseAddress, frame.count)
        }
        return written == frame.count
    }

    /// Czysta enkoder ramki — bez syscalli, testowalna bez prawdziwego
    /// socketu ani uruchomionego Discorda. `internal`, nie `private`.
    static func encodeFrame(opcode: Int32, json: [String: Any]) -> Data? {
        guard let payload = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        var frame = Data(withUnsafeBytes(of: opcode.littleEndian) { Array($0) })
        frame.append(contentsOf: withUnsafeBytes(of: Int32(payload.count).littleEndian) { Array($0) })
        frame.append(payload)
        return frame
    }
}
