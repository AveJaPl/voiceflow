import SwiftUI
import Combine

@MainActor
final class KeyboardPanelModel: ObservableObject {
    @Published var phase: KeyboardSessionSnapshot.Phase = .idle
    @Published var level: Float = 0
    @Published var message = "Włącz sesję, aby dyktować z klawiatury."
    @Published var result = ""
    @Published var consumed = false
    @Published var fullAccess = false
    @Published var automatic = KeyboardSessionStore.automaticallyInsert
    @Published var ready = false
    @Published var needsGlobe = false
    @Published var openURL: URL?
}

struct VoiceKeyboardPanel: View {
    @ObservedObject var model: KeyboardPanelModel
    let start: () -> Void
    let stop: () -> Void
    let insert: () -> Void
    let end: () -> Void
    let next: () -> Void
    @Environment(\.openURL) private var openURL

    private let surface = Color(red: 0.18, green: 0.18, blue: 0.20)
    private var busy: Bool { model.phase == .processing || model.phase == .preparing }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("VoiceFlow").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.ready {
                    Button("Wyłącz sesję", action: end).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
            }
            VoiceRecordingPill(level: model.level,
                label: model.phase == .processing ? "Domykam…" : model.phase == .recording ? "Słucham" : "VoiceFlow",
                active: model.phase == .recording,
                icon: model.phase == .processing ? "ellipsis" : "mic.fill")
            if !model.result.isEmpty {
                ScrollView {
                    Text(model.result).font(.system(size: 15)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 106)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text(model.fullAccess ? model.message : "Włącz Pełny dostęp w Ustawieniach klawiatury VoiceFlow.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 54)
            }
            HStack(spacing: 10) {
                Button {
                    if model.phase == .recording { stop() }
                    else {
                        start()
                        if let url = model.openURL {
                            model.openURL = nil
                            openURL(url) { accepted in
                                if !accepted { model.message = "Otwórz VoiceFlow i włącz sesję klawiatury. Potem wróć tutaj." }
                            }
                        }
                    }
                } label: {
                    Label(model.phase == .recording ? "Zakończ" : model.result.isEmpty ? (model.ready ? "Dyktuj" : "Włącz sesję") : "Nowe dyktowanie",
                          systemImage: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!model.fullAccess || busy)
                if !model.result.isEmpty {
                    Button(action: insert) {
                        Text(model.consumed ? "Wklejono" : "Wklej tekst")
                            .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                    }.disabled(model.consumed)
                }
            }
            HStack {
                if model.needsGlobe {
                    Button(action: next) { Image(systemName: "globe").frame(width: 36, height: 28) }
                        .accessibilityLabel("Zmień klawiaturę")
                }
                Spacer()
                Text(model.automatic ? "Automatyczne wklejanie włączone" : "Wklejanie ręczne")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface).foregroundStyle(.white)
    }
}
