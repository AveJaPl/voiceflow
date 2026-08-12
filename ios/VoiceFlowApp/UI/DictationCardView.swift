import SwiftUI

/// Karta "mikrofon + tekst na żywo", w pełni samowystarczalna (własny
/// `ContainerDictationEngine`). UŻYWANA W DWÓCH MIEJSCACH — to jest CELOWE,
/// nie duplikacja: (1) krok testu dyktowania w onboardingu
/// (`OnboardingView`, krok `.testDictation` — to najważniejszy krok
/// tutorialu, "dowód że działa" zamiast deklaracji), (2) ekran dyktowania
/// otwierany z klawiatury przez `voiceflow://dictate`
/// (`KeyboardHandoffView`). Wojtek wprost poprosił, żeby to był JEDEN
/// mechanizm, nie dwa równoległe.
struct DictationCardView: View {
    /// `true` w onboardingu (mniej paddingu, bez nawigacji na pełny ekran),
    /// `false` na zakładce głównej (pełny ekran, wyśrodkowane pionowo).
    var compact: Bool = false
    /// Czy zapisywać sfinalizowane dyktowanie do historii (App Group) —
    /// TAK przy dyktowaniu z klawiatury, NIE w trakcie testu onboardingu (to
    /// tylko próba, nie realna treść do zachowania).
    var recordsToHistory: Bool = true
    /// PIVOT #2 (docs/plans/ios-voiceflow-app.md §7): `true` wyłącznie gdy
    /// apka została otwarta przez klawiaturę (`voiceflow://dictate`) —
    /// user już kliknął mikrofon W KLAWIATURZE, otworzył apkę PO TO żeby
    /// dyktować, więc nie każemy mu kliknąć drugi raz.
    var autoStart: Bool = false
    /// Wołane raz, gdy nagrywanie zainicjowane przez `autoStart` kończy się
    /// (cisza / user dotyka mikrofonu ponownie) z niepustym tekstem — tylko
    /// dla ścieżki klawiatury, patrz `KeyboardHandoffView`.
    var onFinished: ((String) -> Void)? = nil

    @StateObject private var engine = ContainerDictationEngine()
    @State private var hasAutoStarted = false

    var body: some View {
        VStack(spacing: compact ? 20 : 32) {
            if !compact { Spacer() }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(engine.state == .listening ? VFColor.text : VFColor.faint)
                        .frame(width: 9, height: 9)
                    Text(statusLabel)
                        .font(VFFont.mono(11))
                        .tracking(2)
                        .foregroundStyle(VFColor.muted)
                }
                Text(engine.liveText.isEmpty ? "…" : engine.liveText)
                    .font(VFFont.mono(15))
                    .foregroundStyle(VFColor.text)
                    .frame(minHeight: compact ? 56 : 80, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(compact ? 18 : 24)
            .background(VFColor.surface)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))

            Button {
                engine.toggle(recordToHistory: recordsToHistory)
            } label: {
                ZStack {
                    Circle()
                        .fill(engine.state == .listening ? VFColor.text : VFColor.surfaceSolid)
                        .frame(width: 74, height: 74)
                    Circle()
                        .strokeBorder(VFColor.border, lineWidth: 1)
                        .frame(width: 74, height: 74)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(engine.state == .listening ? VFColor.background : VFColor.text)
                }
            }
            .buttonStyle(.plain)

            if case .error(let message) = engine.state {
                Text(message)
                    .font(VFFont.body(12))
                    .foregroundStyle(VFColor.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if engine.state == .listening || engine.state == .requestingPermission {
                // Landmina znana z innych apek dyktujących przez rozszerzenie
                // klawiatury (dokumentowana przez Wispr Flow) — iOS czasem
                // przełącza na inną apkę, żeby aktywować sesję mikrofonu.
                // NIE zaobserwowane jeszcze na żywo na tym urządzeniu w tej
                // turze (telefon był zablokowany w trakcie budowy) — dodane
                // defensywnie, żeby user nie utknął w niezrozumieniu, jeśli
                // się zdarzy. Ten ekran to kontener/DictationCardView, nie
                // klawiatura — ale ten sam silnik ASR/mikrofon, więc to samo
                // ryzyko systemowe dotyczy obu.
                Text("Jeśli system przełączy Cię do innej apki, przesuń palcem od dolnej krawędzi ekranu, żeby wrócić.")
                    .font(VFFont.body(11.5))
                    .foregroundStyle(VFColor.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if !compact {
                Spacer()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .background(compact ? Color.clear : VFColor.background)
        .onAppear {
            guard autoStart, !hasAutoStarted else { return }
            hasAutoStarted = true
            engine.toggle(recordToHistory: recordsToHistory)
        }
        .onChange(of: engine.state) { oldValue, newValue in
            guard onFinished != nil, oldValue == .listening, newValue == .idle else { return }
            let finalText = engine.liveText
            guard !finalText.isEmpty else { return }
            onFinished?(finalText)
        }
    }

    private var statusLabel: String {
        switch engine.state {
        case .idle: return "STUKNIJ, BY DYKTOWAĆ"
        case .requestingPermission: return "PROSZĘ O ZGODĘ"
        case .listening: return "SŁUCHAM"
        case .error: return "BŁĄD"
        }
    }
}
