import SwiftUI

/// Pierwsza zakładka — „Klawiatura”. Odpowiada na trzy pytania, które ma
/// każdy, kto zainstalował apkę: czy klawiatura jest włączona, czy model
/// jest gotowy, jak dyktować. Do tego jeden przycisk „Dyktuj teraz”, gdy
/// ktoś chce podyktować coś do schowka bez wychodzenia z apki.
struct KeyboardTabView: View {
    @ObservedObject var models: WhisperModelStore
    var onDictate: () -> Void

    @State private var diagnostics = KeyboardStatus.load()
    @State private var refreshTimer: Timer?

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    keyboardCard
                    modelCard
                    howTo
                    Button {
                        onDictate()
                    } label: {
                        HStack {
                            Image(systemName: "mic.fill")
                            Text("Dyktuj teraz")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                        }
                    }
                    .buttonStyle(VFOutlineButtonStyle(solid: true))
                }
                .padding(24)
            }
        }
        .navigationTitle("Klawiatura")
        .onAppear {
            diagnostics = KeyboardStatus.load()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                diagnostics = KeyboardStatus.load()
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DYKTOWANIE").vfEyebrow()
            Text("W dowolnej aplikacji przełącz klawiaturę na VoiceFlow i stuknij mikrofon.")
                .font(VFFont.body(12.5))
                .foregroundStyle(VFColor.faint)
        }
        .padding(.top, 12)
    }

    private var keyboardCard: some View {
        VStack(spacing: 0) {
            StatusRow(label: "Klawiatura włączona", value: diagnostics.launched ? "TAK" : "NIE", ok: diagnostics.launched)
            StatusRow(label: "Pełny dostęp", value: diagnostics.fullAccess ? "TAK" : "NIE", ok: diagnostics.fullAccess)
            if !diagnostics.launched || !diagnostics.fullAccess {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("Włącz w Ustawieniach systemowych")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                    }
                    .font(VFFont.body(13))
                    .foregroundStyle(VFColor.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(VFColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MODEL NA TELEFONIE").vfEyebrow()
            ModelStatusView(models: models)
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("JAK TO DZIAŁA").vfEyebrow()
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Stuknij mikrofon na klawiaturze VoiceFlow — otworzy się ta apka.")
                step(2, "Mów. Stuknij mikrofon ponownie, gdy skończysz.")
                step(3, "Wróć do poprzedniej aplikacji — tekst wstawi się sam.")
            }
            Text("Nagranie i tekst nie opuszczają telefonu. Konto (Ustawienia) tylko synchronizuje historię z Makiem.")
                .font(VFFont.body(12))
                .foregroundStyle(VFColor.faint)
                .padding(.top, 4)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(VFFont.mono(12))
                .foregroundStyle(VFColor.faint)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(VFFont.body(13.5))
                .foregroundStyle(VFColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Stan modelu whisper — jeden widok, używany na zakładce Klawiatura i w
/// Ustawieniach, żeby oba mówiły dokładnie to samo.
struct ModelStatusView: View {
    @ObservedObject var models: WhisperModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(models.selected.title)
                    .font(VFFont.body(14, weight: .semibold))
                    .foregroundStyle(VFColor.text)
                Spacer()
                Text(statusLabel)
                    .font(VFFont.mono(11))
                    .tracking(1)
                    .foregroundStyle(VFColor.muted)
            }
            if case .downloading(let fraction) = models.phase {
                ProgressView(value: fraction)
                    .tint(VFColor.text)
                Text("Pobieram \(models.selected.approximateMB) MB — dyktowanie działa już teraz przez Apple, whisper włączy się sam po pobraniu.")
                    .font(VFFont.body(12))
                    .foregroundStyle(VFColor.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let message) = models.phase {
                Text(message)
                    .font(VFFont.body(12))
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Spróbuj ponownie") { models.retry() }
                    .buttonStyle(VFOutlineButtonStyle())
            } else {
                Text(models.selected.detail)
                    .font(VFFont.body(12))
                    .foregroundStyle(VFColor.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VFColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
    }

    private var statusLabel: String {
        switch models.phase {
        case .idle: "CZEKA"
        case .downloading(let fraction): "POBIERAM \(Int(fraction * 100))%"
        case .loading: "ŁADUJĘ"
        case .ready: "GOTOWY"
        case .failed: "BŁĄD"
        }
    }
}

struct KeyboardStatus {
    let launched: Bool
    let fullAccess: Bool

    static func load() -> KeyboardStatus {
        let d = AppGroup.defaults
        return KeyboardStatus(
            launched: d.bool(forKey: AppGroupKeys.keyboardHasLaunched),
            fullAccess: d.bool(forKey: AppGroupKeys.keyboardHasFullAccessObserved)
        )
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
            Spacer()
            Text(value)
                .font(VFFont.mono(12))
                .foregroundStyle(ok ? VFColor.text : VFColor.faint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VFColor.border).frame(height: 1).padding(.horizontal, 18)
        }
    }
}
