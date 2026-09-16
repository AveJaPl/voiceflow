import SwiftUI
import AppKit

/// Napędza wygląd pilla. Realny odpowiednik dostarczy SessionController
/// (Core/) — kontrakt to `phase` + `audioLevel` (RMS 0...1) + `liveText` +
/// `resultText`. Podmiana źródeł jest jednym przypisaniem, PillView o tym nie wie.
final class PillViewModel: ObservableObject {
    @Published var phase: PillPhase = .idle
    @Published var audioLevel: Float = 0
    /// Tekst BIEŻĄCEJ wypowiedzi (od ostatniego wciśnięcia skrótu) — nie cała
    /// narastająca sesja. SessionController sam odcina starą część.
    @Published var liveText: String = ""
    /// Nazwa terminala, dla którego tryb nasłuchu zbiera teraz prompt
    /// („terminal pierwszy nasłuchuj…"). `nil` = nasłuch nie zbiera.
    @Published var ambientTarget: String?
    /// Pełny tekst po zakończeniu dyktowania — pokazywany w `.result` z
    /// przyciskiem kopiowania.
    @Published var resultText: String = ""
    /// Rośnie za każdym razem, gdy pill ma odegrać wjazd sprężysty od nowa
    /// (np. nowe uzbrojenie po ciszy) — sterowane z zewnątrz, PillView tylko nasłuchuje.
    @Published var armTrigger: Int = 0

    init(phase: PillPhase = .idle, audioLevel: Float = 0, liveText: String = "", resultText: String = "") {
        self.phase = phase
        self.audioLevel = audioLevel
        self.liveText = liveText
        self.resultText = resultText
    }
}

/// Fixed recording surface; only a failed insertion expands to a result card.
struct PillView: View {
    @ObservedObject var model: PillViewModel
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                if model.phase == .listening || model.phase == .transcribing {
                    VoiceWaveform(level: model.audioLevel).frame(width: 124, height: 22)
                } else {
                    Text(label).font(.system(size: 12, weight: .medium))
                        .frame(width: 124, height: 22)
                }
            }
            if model.phase == .result {
                ScrollView { Text(model.resultText).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 60)
                Button(justCopied ? "Skopiowano" : "Kopiuj tekst") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.resultText, forType: .string)
                    justCopied = true
                }.buttonStyle(.bordered).controlSize(.small)
            }
            if case .error(let reason) = model.phase {
                Text(reason).font(.system(size: 12)).lineLimit(3)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(Color(red: 0.075, green: 0.075, blue: 0.085))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .padding(4)
        .onChange(of: model.phase) { _, _ in justCopied = false }
        .accessibilityLabel(label)
    }

    private var icon: String {
        switch model.phase {
        case .finalizing: "ellipsis"
        case .result: "checkmark"
        case .error: "exclamationmark.triangle"
        default: "mic.fill"
        }
    }
    private var label: String {
        switch model.phase {
        case .idle: "VoiceFlow"
        case .arming: "Przygotowuję…"
        case .listening, .transcribing: "Słucham"
        case .finalizing: "Domykam…"
        case .result: "Gotowe"
        case .error: "Nie udało się"
        }
    }
}
