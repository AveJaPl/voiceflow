import SwiftUI

/// Ustawienia + panel diagnostyczny klawiatury. Panel diagnostyczny czyta
/// WYŁĄCZNIE to, co rozszerzenie zdążyło zapisać do App Group — to jedyny
/// kanał komunikacji między kontenerem a rozszerzeniem (patrz `AppGroup.swift`).
/// To tutaj Wojtek/Ty zobaczycie realny wynik kryterium #4 z planu bez
/// podpinania Console.app.
struct SettingsView: View {
    @ObservedObject var remote: RemoteSession
    @State private var diagnostics = KeyboardDiagnostics.load()
    @State private var refreshTimer: Timer?

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DIAGNOSTYKA KLAWIATURY")
                            .vfEyebrow()
                        Text("Ostatni zaobserwowany stan rozszerzenia, przez App Group.")
                            .font(VFFont.body(12.5))
                            .foregroundStyle(VFColor.faint)
                    }
                    .padding(.top, 20)

                    VStack(spacing: 0) {
                        DiagnosticRow(label: "Klawiatura uruchamiana", value: diagnostics.launched ? "TAK" : "NIE")
                        DiagnosticRow(label: "Pełny dostęp (ostatnio)", value: diagnostics.fullAccess ? "TAK" : "NIE")
                        DiagnosticRow(label: "AVAudioEngine wystartował", value: diagnostics.micStarted ? "TAK" : diagnostics.hasAnyResult ? "NIE" : "BRAK PRÓBY")
                        if let err = diagnostics.lastError, !err.isEmpty {
                            DiagnosticRow(label: "Ostatni błąd", value: err, isMultiline: true)
                        }
                    }
                    .background(VFColor.surface)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("ZDALNE STEROWANIE MAKIEM").vfEyebrow()
                        Text(remote.isPaired
                             ? "Sparowano. Zakładka „Mac” pokazuje okna i pozwala dyktować do wybranego."
                             : "Sparuj z Makiem, żeby widzieć jego okna i dyktować do nich z telefonu.")
                            .font(VFFont.body(12.5))
                            .foregroundStyle(VFColor.faint)
                        NavigationLink {
                            PairingView(session: remote)
                        } label: {
                            HStack {
                                Text(remote.isPaired ? "Zmień parowanie" : "Sparuj z Makiem")
                                Spacer()
                                Image(systemName: "qrcode")
                            }
                        }
                        .buttonStyle(VFOutlineButtonStyle(solid: !remote.isPaired))
                    }

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Text("Otwórz Ustawienia systemowe")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                        }
                    }
                    .buttonStyle(VFOutlineButtonStyle())

                    VStack(alignment: .leading, spacing: 6) {
                        Text("O APLIKACJI")
                            .vfEyebrow()
                        // Wersja z Info.plist, nie z palca — po każdej publikacji
                        // podbija się sama razem z `project.yml`.
                        Text("VoiceFlow · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                            .font(VFFont.body(13))
                            .foregroundStyle(VFColor.muted)
                        Text("Rozpoznawanie mowy działa w całości na urządzeniu (SFSpeechRecognizer, on-device, pl-PL) — nagranie nigdy nie opuszcza telefonu.")
                            .font(VFFont.body(12.5))
                            .foregroundStyle(VFColor.faint)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Ustawienia")
        .onAppear {
            diagnostics = KeyboardDiagnostics.load()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                diagnostics = KeyboardDiagnostics.load()
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }
}

private struct KeyboardDiagnostics {
    let launched: Bool
    let fullAccess: Bool
    let micStarted: Bool
    let hasAnyResult: Bool
    let lastError: String?

    static func load() -> KeyboardDiagnostics {
        let d = AppGroup.defaults
        return KeyboardDiagnostics(
            launched: d.bool(forKey: AppGroupKeys.keyboardHasLaunched),
            fullAccess: d.bool(forKey: AppGroupKeys.keyboardHasFullAccessObserved),
            micStarted: d.bool(forKey: AppGroupKeys.keyboardMicEngineStartSucceeded),
            hasAnyResult: d.object(forKey: AppGroupKeys.keyboardMicEngineStartSucceeded) != nil,
            lastError: d.string(forKey: AppGroupKeys.keyboardMicEngineLastError)
        )
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String
    var isMultiline: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(VFFont.body(13))
                .foregroundStyle(VFColor.muted)
            Spacer()
            Text(value)
                .font(VFFont.mono(12))
                .foregroundStyle(VFColor.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(isMultiline ? 3 : 1)
                .frame(maxWidth: isMultiline ? 200 : nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VFColor.border).frame(height: 1).padding(.horizontal, 18)
        }
    }
}
