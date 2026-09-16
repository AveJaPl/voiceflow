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
    @State private var levelHistory: [Float] = Array(repeating: 0, count: PillWaveform.barCount)
    /// Poziom po wygładzeniu atak/opadanie (patrz `pushLevel`) — z tego rosną słupki.
    @State private var smoothedLevel: Float = 0
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
            if newValue == .arming || newValue == .idle {
                smoothedLevel = 0
                levelHistory = Array(repeating: 0, count: PillWaveform.barCount)
            }
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

        case .listening, .transcribing:
            // Fala żyje przez CAŁE mówienie, także gdy niżej pojawia się już
            // tekst — wcześniej gasła w chwili pierwszego słowa i zostawała
            // statyczna ikona, a pill wyglądał, jakby przestał słuchać.
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(accentColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && smoothedLevel < 0.01)
                PillWaveform(levels: levelHistory, tint: accentColor, reduceMotion: reduceMotion)
                    .frame(width: 132, height: 22)
            }

        case .finalizing:
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(accentColor)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                Text("Domykam…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

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

    /// Wygładzanie w stylu miernika: szybki atak (sylaba od razu podbija
    /// słupek), wolne opadanie (nie migocze między głoskami). Surowy RMS z
    /// bufora 1024 próbek przychodzi ~47 razy na sekundę i bez tego pasek
    /// wyglądał jak szum, nie jak mowa.
    private func pushLevel(_ level: Float) {
        let attack: Float = 0.25
        let release: Float = 0.12
        if level > smoothedLevel {
            smoothedLevel += (level - smoothedLevel) * attack
        } else {
            smoothedLevel += (level - smoothedLevel) * release
        }
        levelHistory.removeFirst()
        levelHistory.append(smoothedLevel)
    }

    private func replayArmingAnimation() {
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            appeared = true
        }
    }
}

/// Fala dźwięku sterowana realnym poziomem: ostatnie `barCount` wygładzonych
/// próbek RMS jako słupki rosnące SYMETRYCZNIE od osi poziomej.
///
/// Dwie rzeczy, które ta wersja naprawia (zgłoszenie 2026-09-14):
/// 1. „Przy ciszy kreska idzie do góry” — poprzedni `HStack` siedział w
///    `GeometryReader`, który kładzie zawartość w LEWYM GÓRNYM rogu; przy
///    ciszy słupki miały 2 px, cały pasek 2 px wysokości i wisiał u góry ramki.
///    Teraz każdy słupek ma pełną wysokość ramki i rysuje kapsułę wokół
///    środka — oś jest zawsze na środku, niezależnie od poziomu.
/// 2. „Mało dynamiczne” — słupki dostają sprężynę na zmianę wysokości, a przy
///    ciszy zamiast płaskiej kreski widać wolny „oddech” (sinusoida o małej
///    amplitudzie), żeby było widać, że mikrofon żyje.
struct PillWaveform: View {
    static let barCount = 28

    let levels: [Float]
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(tint.opacity(opacity(index: index)))
                        .frame(width: barWidth, height: barHeight(level: level, index: index, phase: phase))
                        .frame(maxHeight: .infinity, alignment: .center)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.16),
                            value: level
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var barWidth: CGFloat { 2.6 }
    private var maxHeight: CGFloat { 14 }

    private func opacity(index: Int) -> Double {
        // Najnowsze próbki po prawej — najjaśniejsze; ogon po lewej gaśnie.
        let fraction = Double(index) / Double(max(levels.count - 1, 1))
        return 0.3 + 0.7 * fraction
    }

    private func barHeight(level: Float, index: Int, phase: TimeInterval) -> CGFloat {
        // Skala wyłącznie wizualna: mniejsze wzmocnienie zachowuje zapas
        // dla głośnych sylab, bez zmiany czułości mikrofonu i rozpoznawania.
        let boosted = min(1, pow(CGFloat(max(0, level)) * 2.5, 0.9))
        let fromAudio = boosted * maxHeight
        // Oddech przy ciszy: fala 0,8 Hz, tylko 2–3 px.
        let breath = reduceMotion ? 2 : 2.5 + 0.5 * sin(phase * 2 * .pi * 0.8 + Double(index) * 0.35)
        return max(CGFloat(breath), fromAudio)
    }
}
