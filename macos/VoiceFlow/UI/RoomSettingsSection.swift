import SwiftUI

/// Sekcja ustawień pokoju: utworzenie, dołączenie kodem, wyjście.
///
/// Samowystarczalna — czyta i zapisuje `UserDefaults` bezpośrednio, zamiast
/// dokładać pola do `SettingsModel`. Ta sekcja ma jeden własny cykl życia
/// (dołącz / wyjdź) i nic z nią nie współdzieli stanu, więc trzymanie jej
/// osobno jest tańsze niż wplatanie w model, który obsługuje wszystko inne.
struct RoomSettingsSection: View {

    @AppStorage(SettingsKeys.roomEnabled) private var enabled = false
    @AppStorage(SettingsKeys.roomServer) private var server = "wss://rooms.pbdevs.com"
    @AppStorage(SettingsKeys.roomCode) private var code = ""
    @AppStorage(SettingsKeys.roomDuckForOthers) private var duckForOthers = true
    @AppStorage(SettingsKeys.roomDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.roomShareClaudeUsage) private var shareClaudeUsage = true

    @State private var joinCode = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private var canAct: Bool {
        !busy && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Section("Wspólny pokój dyktowania") {
            if enabled, !code.isEmpty {
                LabeledContent("Jesteś w pokoju", value: code)
                Link("Ranking na żywo",
                     destination: URL(string: "\(httpServer)/room/\(code)") ?? URL(string: "https://voiceflow.pbdevs.com")!)
                Toggle("Pozwól, by cudze dyktowanie ściszało dźwięk tutaj", isOn: $duckForOthers)
                Text("Kiedy ktoś inny w pokoju mówi, Twój skrót nie zacznie nagrywać — dwa mikrofony naraz psują obie transkrypcje. Zmiana wymaga restartu VoiceFlow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("Pokazuj w pokoju zużycie Claude Code", isOn: $shareClaudeUsage)
                Text("Na tablicę pokoju trafiają wyłącznie liczby: tokeny z dzisiaj i procenty limitów. Nigdy nazwy sesji, katalogi ani treść. Zmiana wymaga restartu VoiceFlow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Wyjdź z pokoju") {
                    RoomJoiner.leave()
                    enabled = false
                    message = "Wyszedłeś z pokoju. Dyktowanie działa dalej, lokalnie. Zrestartuj VoiceFlow."
                    failed = false
                }
            } else {
                TextField("Twoja nazwa w rankingu", text: $displayName)
                TextField("Serwer", text: $server)
                HStack {
                    TextField("Kod pokoju", text: $joinCode)
                        .textCase(.uppercase)
                    Button("Dołącz") { Task { await join() } }
                        .disabled(!canAct || joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Utwórz nowy pokój") { Task { await create() } }
                    .disabled(!canAct)
                Text("Bez pokoju VoiceFlow działa dokładnie jak dziś, w pełni lokalnie. Po dołączeniu na serwer trafiają wyłącznie zdarzenia „zaczynam/kończę mówić\" oraz liczba słów i sekund — nagranie i tekst nigdy.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if busy {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? .red : .secondary)
            }
        }
    }

    private var httpServer: String {
        (try? RoomJoiner.httpBase(server)) ?? "https://rooms.pbdevs.com"
    }

    private func create() async {
        await run {
            let joined = try await RoomJoiner.createRoom(
                server: server,
                roomName: nil,
                displayName: displayName,
                existingToken: UserDefaults.standard.string(forKey: SettingsKeys.roomToken) ?? ""
            )
            RoomJoiner.save(joined, server: server)
            code = joined.code
            enabled = true
            return "Pokój \(joined.code) utworzony. Zrestartuj VoiceFlow, żeby dołączyć."
        }
    }

    private func join() async {
        await run {
            let joined = try await RoomJoiner.joinRoom(
                server: server,
                code: joinCode,
                displayName: displayName,
                existingToken: UserDefaults.standard.string(forKey: SettingsKeys.roomToken) ?? ""
            )
            RoomJoiner.save(joined, server: server)
            code = joined.code
            enabled = true
            return "Dołączono do \(joined.code). Zrestartuj VoiceFlow."
        }
    }

    /// Wspólna obsługa: kręcioł, komunikat i to, żeby błąd sieci nie wyglądał
    /// jak brak reakcji przycisku.
    private func run(_ work: @escaping () async throws -> String) async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            message = try await work()
            failed = false
        } catch {
            message = error.localizedDescription
            failed = true
        }
    }
}
