import SwiftUI

/// Sekcja ustawień pokoju: utworzenie, dołączenie kodem, wyjście.
///
/// Samowystarczalna — czyta i zapisuje `UserDefaults` bezpośrednio, zamiast
/// dokładać pola do `SettingsModel`. Ta sekcja ma jeden własny cykl życia
/// (dołącz / wyjdź) i nic z nią nie współdzieli stanu, więc trzymanie jej
/// osobno jest tańsze niż wplatanie w model, który obsługuje wszystko inne.
struct RoomSettingsSection: View {

    @AppStorage(SettingsKeys.roomEnabled) private var enabled = false
    @AppStorage(SettingsKeys.roomServer) private var server = RoomConfiguration.defaultServer
    @AppStorage(SettingsKeys.roomCode) private var code = ""
    @AppStorage(SettingsKeys.roomDuckForOthers) private var duckForOthers = true
    @AppStorage(SettingsKeys.roomDisplayName) private var displayName = ""

    @State private var joinCode = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private var canAct: Bool {
        !busy && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VFSection(title: "Wspólny pokój dyktowania") {
            if enabled, !code.isEmpty {
                VFRow(title: "Jesteś w pokoju") {
                    Text(code)
                        .font(VF.Font.mono(13))
                        .foregroundStyle(VF.Color.text)
                }
                Link("Ranking na żywo",
                     destination: URL(string: "\(httpServer)/room/\(code)") ?? URL(string: "https://voiceflow.pbdevs.com")!)
                    .font(VF.Font.body(12))
                    .foregroundStyle(VF.Color.muted)
                VFSettingToggle(
                    title: "Pozwól, by cudze dyktowanie ściszało dźwięk tutaj",
                    isOn: $duckForOthers
                )
                VFHint("Kiedy ktoś inny w pokoju mówi, Twój skrót nie zacznie nagrywać — dwa mikrofony naraz psują obie transkrypcje. Zmiana wymaga restartu VoiceFlow.")
                Button("Wyjdź z pokoju") {
                    RoomJoiner.leave()
                    enabled = false
                    message = "Wyszedłeś z pokoju. Dyktowanie działa dalej, lokalnie. Zrestartuj VoiceFlow."
                    failed = false
                }
                .buttonStyle(VFButtonStyle())
            } else {
                VFTextField(placeholder: "Twoja nazwa w rankingu", text: $displayName)
                VFTextField(placeholder: "Serwer", text: $server)
                HStack(spacing: VF.Space.x8) {
                    VFTextField(placeholder: "Kod pokoju", text: $joinCode)
                        .textCase(.uppercase)
                    Button("Dołącz") { Task { await join() } }
                        .buttonStyle(VFButtonStyle())
                        .disabled(!canAct || joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Utwórz nowy pokój") { Task { await create() } }
                    .buttonStyle(VFButtonStyle(prominent: true))
                    .disabled(!canAct)
                VFHint("Bez pokoju VoiceFlow działa dokładnie jak dziś, w pełni lokalnie. Po dołączeniu na serwer trafiają wyłącznie zdarzenia „zaczynam/kończę mówić” oraz liczba słów i sekund — nagranie i tekst nigdy.")
            }

            if busy {
                ProgressView().controlSize(.small)
            }
            if let message {
                // Czerwień niesie w tym interfejsie jedno znaczenie (nagrywanie),
                // więc błąd wyróżnia się jasnością tekstu, nie kolorem.
                Text(message)
                    .font(VF.Font.body(11))
                    .foregroundStyle(failed ? VF.Color.text : VF.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
