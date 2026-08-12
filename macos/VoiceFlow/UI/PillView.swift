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

/// Zawartość pływającego pilla — totalny redesign 2026-08-09.
///
/// Poprzednia wersja trzymała waveform i tekst OBOK SIEBIE w jednej linii
/// (HStack) i mimo dwóch napraw wciąż potrafiła się nachodzić przy zmianach
/// szerokości okna w locie. Nowy układ eliminuje CAŁĄ tę klasę błędów:
/// ikona/waveform i tekst są teraz w OSOBNYCH WIERSZACH (VStack), tekst
/// zawija się na maks. 3 linie zamiast być ucinany w jednej — nic nie może
/// nachodzić na nic, bo nie dzielą tej samej linii ani przestrzeni.
struct PillView: View {
    @ObservedObject var model: PillViewModel
    @State private var appeared = false
    @State private var levelHistory: [Float] = Array(repeating: 0, count: 24)
    @State private var justCopied = false
    @Environment(\.colorScheme) private var colorScheme

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            textBlock
            if model.phase == .result {
                resultActions
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(minWidth: 220, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.15), radius: 14, y: 5)
        .scaleEffect(appeared ? 1.0 : 0.92)
        .opacity(appeared ? 1.0 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72), value: appeared)
        .animation(reduceMotion ? .linear(duration: 0.12) : .default, value: model.phase)
        .onChange(of: model.audioLevel) { _, newValue in
            pushLevel(newValue)
        }
        .onChange(of: model.armTrigger) { _, _ in
            replayArmingAnimation()
        }
        .onChange(of: model.phase) { _, newValue in
            if newValue != .result { justCopied = false }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Górny wiersz: ikona + krótki status (NIGDY tekst dyktowania)

    @ViewBuilder
    private var header: some View {
        switch model.phase {
        case .idle:
            EmptyView()

        case .arming:
            statusRow(icon: "mic.fill", label: "Uzbrajam mikrofon…", tinted: false)

        case .listening:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(accentColor)
                WaveformView(levels: levelHistory, pulsing: false, tint: accentColor)
                    .frame(width: 120, height: 20)
            }

        case .transcribing:
            statusRow(icon: "waveform", label: "Słucham…", tinted: true)

        case .finalizing:
            statusRow(icon: "checkmark", label: "Domykam…", tinted: true)

        case .result:
            statusRow(icon: "checkmark.circle.fill", label: "Gotowe", tinted: true)

        case .error:
            statusRow(icon: "exclamationmark.triangle.fill", label: "Błąd", tinted: false, isError: true)
        }
    }

    private func statusRow(icon: String, label: String, tinted: Bool, isError: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isError ? .red : (tinted ? accentColor : .secondary))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Blok tekstu — WŁASNY WIERSZ, zawija się, nigdy nie dzieli linii z ikoną/waveformem

    @ViewBuilder
    private var textBlock: some View {
        switch model.phase {
        case .transcribing:
            Text(model.liveText.isEmpty ? " " : model.liveText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: model.liveText)

        case .result:
            ScrollView {
                Text(model.resultText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 460, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460, maxHeight: 76, alignment: .topLeading)

        case .error(let reason):
            Text(reason)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 400, alignment: .leading)

        case .idle, .arming, .listening, .finalizing:
            EmptyView()
        }
    }

    // MARK: - Przyciski pod wynikiem

    private var resultActions: some View {
        HStack {
            Spacer()
            Button {
                copyResult()
            } label: {
                Label(justCopied ? "Skopiowano" : "Kopiuj", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.resultText, forType: .string)
        justCopied = true
    }

    // MARK: - Kolory

    private var accentColor: Color {
        colorScheme == .dark ? Color(nsColor: .white) : Color(nsColor: .black)
    }

    private var borderColor: Color {
        switch model.phase {
        case .error:
            Color.red.opacity(0.5)
        default:
            colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
    }

    private func pushLevel(_ level: Float) {
        levelHistory.removeFirst()
        levelHistory.append(level)
    }

    private func replayArmingAnimation() {
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            appeared = true
        }
    }
}

/// Waveform sterowany realnym poziomem audio — historia ostatnich N próbek
/// renderowana jako słupki. Używany TYLKO w stanie `.listening`, zanim
/// pojawi się jakikolwiek tekst — nigdy obok tekstu, więc nie ma czego nachodzić.
private struct WaveformView: View {
    let levels: [Float]
    let pulsing: Bool
    let tint: Color

    @State private var pulsePhase: CGFloat = 0

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        GeometryReader { geo in
            let barCount = levels.count
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (geo.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(tint.opacity(pulsing ? 0.55 : barOpacity(index: index, count: barCount)))
                        .frame(width: barWidth, height: barHeight(level: level, index: index, height: geo.size.height))
                }
            }
        }
        .onAppear {
            guard pulsing, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsePhase = 1
            }
        }
    }

    private func barOpacity(index: Int, count: Int) -> Double {
        let fraction = Double(index) / Double(max(count - 1, 1))
        return 0.35 + 0.65 * fraction
    }

    private func barHeight(level: Float, index: Int, height: CGFloat) -> CGFloat {
        if pulsing {
            let base: CGFloat = height * 0.35
            let wobble = sin((CGFloat(index) * 0.7) + pulsePhase * .pi * 2) * height * 0.15
            return max(3, base + wobble)
        }
        // Surowy RMS mowy siedzi w paśmie ~0,02–0,15 — liniowo dawało słupki
        // po 3 px, czyli równą kreskę zamiast wykresu („nie widać pasków").
        // Wzmocnienie ×6 rozciąga pasmo mowy na pełną skalę, a wykładnik 0,7
        // spłaszcza szczyty, żeby głośne sylaby nie przyklejały się do sufitu.
        let boosted = min(1, pow(CGFloat(level) * 6, 0.7))
        return max(2, boosted * height)
    }
}
