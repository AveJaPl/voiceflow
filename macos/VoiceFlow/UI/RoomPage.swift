import SwiftUI

/// Zakładka „Pokój" — odpowiednik `app/voiceflow_app/pages/room.py` z Linuksa.
///
/// Dwa stany, tak samo jak tam: poza pokojem (załóż / dołącz / wykryte obok) i
/// w pokoju (kto teraz mówi, zegar sesji, tablica z rankingiem). Liczby na
/// tablicy liczy `RoomBoard`, wzór w wzór jak `roomdata.py` — bo obie platformy
/// patrzą na tę samą sesję i nie mogą pokazywać różnych wyników.
@MainActor
final class RoomPageModel: ObservableObject {
    @Published var snapshot: RoomSnapshot = .empty
    @Published var elapsed = "—"
    @Published var status: String?
    @Published var busy = false

    @Published var joinCode = ""
    @Published var newRoomName = ""
    @Published var displayName = Host.current().localizedName ?? "Mac"
    @Published var sessionName = ""

    let discovery = RoomDiscovery()

    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var config: RoomConfiguration { RoomConfiguration.fromDefaults(defaults) }
    var inRoom: Bool { config.isUsable }

    // MARK: - Cykl życia strony

    func onAppear() {
        discovery.startBrowsing()
        refreshAdvertising()
        // Zegar sesji musi iść co sekundę niezależnie od odpytywania serwera,
        // inaczej stoi w miejscu między odświeżeniami tablicy.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refresh() }
    }

    func onDisappear() {
        timer?.invalidate()
        timer = nil
        discovery.stopBrowsing()
    }

    private func tick() {
        if let startedAt = snapshot.sessionStartedAt {
            elapsed = RoomBoard.sessionElapsed(startedAt: startedAt)
        }
        // Tablica co 5 s — częściej nie ma sensu, bo i tak zmienia się dopiero
        // po czyjejś wypowiedzi.
        secondsSinceRefresh += 1
        if secondsSinceRefresh >= 5 {
            secondsSinceRefresh = 0
            Task { await refresh() }
        }
    }

    private var secondsSinceRefresh = 0

    // MARK: - Dane

    func refresh() async {
        let config = self.config
        guard config.isUsable else {
            snapshot = .empty
            elapsed = "—"
            return
        }
        do {
            snapshot = try await RoomBoardClient.fetchRanking(server: config.server, code: config.code)
            if let startedAt = snapshot.sessionStartedAt {
                elapsed = RoomBoard.sessionElapsed(startedAt: startedAt)
            }
            status = nil
        } catch {
            // Pokój, którego nie widzimy, nie może blokować pracy — ta sama
            // zasada co w `RoomClient.onDisconnected`. Mówimy o tym wprost,
            // zamiast pokazywać starą tablicę jako aktualną.
            status = "Nie udało się odczytać tablicy pokoju."
        }
    }

    private func refreshAdvertising() {
        let config = self.config
        guard config.isUsable else { return discovery.stopAdvertising() }
        discovery.startAdvertising(
            code: config.code,
            roomName: snapshot.sessionName ?? "",
            hostName: displayName
        )
    }

    // MARK: - Akcje

    func createRoom() async {
        await run {
            let joined = try await RoomJoiner.createRoom(
                server: self.config.server,
                roomName: self.newRoomName.isEmpty ? nil : self.newRoomName,
                displayName: self.displayName,
                existingToken: self.config.token
            )
            RoomJoiner.save(joined, server: self.config.server, defaults: self.defaults)
            self.newRoomName = ""
        }
    }

    func joinRoom() async {
        let code = joinCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return }
        await run {
            let joined = try await RoomJoiner.joinRoom(
                server: self.config.server,
                code: code,
                displayName: self.displayName,
                existingToken: self.config.token
            )
            RoomJoiner.save(joined, server: self.config.server, defaults: self.defaults)
            self.joinCode = ""
        }
    }

    func join(_ room: DiscoveredRoom) async {
        joinCode = room.code
        await joinRoom()
    }

    func startSession() async {
        await run {
            try await RoomBoardClient.startSession(
                server: self.config.server, code: self.config.code,
                name: self.sessionName.isEmpty ? nil : self.sessionName,
                token: self.config.token
            )
            self.sessionName = ""
        }
    }

    func endSession() async {
        await run {
            try await RoomBoardClient.endSession(
                server: self.config.server, code: self.config.code, token: self.config.token
            )
        }
    }

    func leaveRoom() {
        RoomJoiner.leave(defaults: defaults)
        discovery.stopAdvertising()
        snapshot = .empty
        elapsed = "—"
    }

    /// Jedno miejsce na „zajęte / błąd / odśwież", żeby każda akcja zachowywała
    /// się tak samo i żadna nie zostawiła zablokowanego przycisku po wyjątku.
    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            await refresh()
            refreshAdvertising()
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "Operacja nie powiodła się."
        }
    }
}

struct RoomPage: View {
    @StateObject private var model = RoomPageModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.inRoom { inside } else { outside }

                if let status = model.status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    // MARK: - Poza pokojem

    private var outside: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Załóż pokój") {
                HStack {
                    TextField("Nazwa (opcjonalnie)", text: $model.newRoomName)
                        .textFieldStyle(.roundedBorder)
                    Button("Załóż") { Task { await model.createRoom() } }
                        .disabled(model.busy)
                }
                Text("Dostaniesz sześcioznakowy kod — podaj go osobie obok albo pozwól, żeby znalazła pokój sama.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            section("Dołącz kodem") {
                HStack {
                    TextField("np. AB12CD", text: $model.joinCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button("Dołącz") { Task { await model.joinRoom() } }
                        .disabled(model.busy || model.joinCode.isEmpty)
                }
            }

            section("W tej sieci") {
                if model.discovery.rooms.isEmpty {
                    Text("Nikt obok nie rozgłasza pokoju. Kod z drugiego komputera zadziała tak samo.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.discovery.rooms) { room in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.title).font(.system(size: 13, weight: .medium))
                                Text(room.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Dołącz") { Task { await model.join(room) } }
                                .disabled(model.busy)
                        }
                    }
                }
            }
        }
    }

    // MARK: - W pokoju

    private var inside: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.snapshot.sessionName ?? "Sesja bez nazwy")
                        .font(.system(size: 20, weight: .semibold))
                    Text("kod \(model.config.code) · trwa \(model.elapsed)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Wyjdź z pokoju") { model.leaveRoom() }
            }

            section("Tablica") {
                if model.snapshot.rows.isEmpty {
                    Text("Jeszcze nikt nic nie podyktował w tej sesji.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.rows) { row in boardRow(row) }
                }
            }

            section("Nowa sesja") {
                HStack {
                    TextField("Nazwa sesji (opcjonalnie)", text: $model.sessionName)
                        .textFieldStyle(.roundedBorder)
                    Button("Zacznij") { Task { await model.startSession() } }
                        .disabled(model.busy)
                    Button("Zakończ bieżącą") { Task { await model.endSession() } }
                        .disabled(model.busy)
                }
                Text("Nowa sesja zeruje tablicę. Poprzednia zamyka się sama — dwie otwarte naraz rozjechałyby ranking.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func boardRow(_ row: BoardRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.position).")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13, weight: .medium))
                Text("\(row.dictations) dyktowań · śr. \(row.averageWords) sł. · \(RoomBoard.formatDuration(seconds: Double(row.seconds)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.words) sł.")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(row.behind == 0 ? "\(row.share)% · lider" : "\(row.share)% · −\(row.behind)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
