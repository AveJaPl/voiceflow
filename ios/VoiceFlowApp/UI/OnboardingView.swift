import SwiftUI

/// Onboarding PROWADZONY, wielokrokowy — wzorzec skopiowany z Wispr Flow
/// (docs.wisprflow.ai), na wyraźną prośbę Wojtka po realnym teście starej
/// sondy 0d: "sama sonda przenosiła do Ustawień i puszczała na wodę, zero
/// tutorialu, zero sposobu sprawdzenia czy zadziałało". Pięć kroków:
/// wyjaśnienie → Ustawienia → przełączenie klawiatury → TEST DYKTOWANIA
/// NA ŻYWO (dowód, nie deklaracja) → gotowe.
///
/// Uczciwość o granicach platformy (patrz docs/plans/ios-voiceflow-app.md
/// §3) zostaje: Apple nie daje API do programowego dodania klawiatury ani
/// do wykrycia "przełączyłeś się na VoiceFlow" — kroki (c) i (d) mają
/// przyciski "Zrobione"/"Dalej" zamiast twardej weryfikacji, bo detekcja
/// byłaby zbyt krucha, żeby dobrze zrobić ją w tym czasie. JEDYNA twarda
/// automatyczna detekcja to `keyboardHasLaunched` z App Group (patrz
/// `pollForAutoCompletion`) — jeśli zadziała w tle na dowolnym kroku,
/// onboarding kończy się sam, natychmiast.
struct OnboardingView: View {
    /// Wołane albo automatycznie (App Group wykryło realne uruchomienie
    /// klawiatury), albo ręcznie (user doszedł do końca prowadzonego
    /// tutorialu i nacisnął "Zacznij korzystać").
    var onComplete: () -> Void

    private enum Step: Int {
        case intro, settings, switchKeyboard, testDictation, done
    }

    @State private var step: Step = .intro
    @State private var didOpenSettings = false
    @State private var pollTimer: Timer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            StepProgressBar(current: step.rawValue, total: Step.done.rawValue + 1)
                .padding(.top, 16)
                .padding(.horizontal, 24)

            ScrollView {
                Group {
                    switch step {
                    case .intro: IntroStepView { advance(to: .settings) }
                    case .settings: SettingsStepView(didOpenSettings: $didOpenSettings)
                    case .switchKeyboard: SwitchKeyboardStepView(
                        onDone: { advance(to: .testDictation) },
                        onSkip: { advance(to: .testDictation) }
                    )
                    case .testDictation: TestDictationStepView(
                        onNext: { advance(to: .done) }
                    )
                    case .done: DoneStepView(onFinish: onComplete)
                    }
                }
                .padding(24)
            }
        }
        .background(VFColor.background)
        .onAppear(perform: startAutoDetectPolling)
        .onDisappear { pollTimer?.invalidate() }
        .onChange(of: scenePhase) { _, newPhase in
            // Wraca z Ustawień systemowych → prowadzimy dalej, do kroku
            // przełączenia klawiatury. To jedyny sygnał "user wrócił", jaki
            // mamy (nie ma callbacku "zamknięto Ustawienia").
            if newPhase == .active, didOpenSettings, step == .settings {
                advance(to: .switchKeyboard)
            }
        }
    }

    private func advance(to newStep: Step) {
        withAnimation(.easeOut(duration: 0.25)) { step = newStep }
    }

    private func startAutoDetectPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            if AppGroup.defaults.bool(forKey: AppGroupKeys.keyboardHasLaunched) {
                pollTimer?.invalidate()
                onComplete()
            }
        }
    }
}

// MARK: - Krok 1: wyjaśnienie

private struct IntroStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                VFWordmark(size: 34)
                Text("SKONFIGURUJMY KLAWIATURĘ")
                    .font(VFFont.display(28, weight: .extrabold))
                    .foregroundStyle(VFColor.text)
                    .textCase(.uppercase)
                    .tracking(-0.5)
                Text("Za chwilę otworzymy Ustawienia systemowe. Tam dodasz klawiaturę VoiceFlow i włączysz jej Pełny dostęp — bez tego mikrofon w klawiaturze nie zadziała.")
                    .font(VFFont.body(14))
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Cztery krótkie kroki, robisz je raz. Poprowadzimy Cię przez każdy — łącznie z testem na żywo na końcu, żebyś od razu zobaczył/a, że działa.")
                    .font(VFFont.body(13))
                    .foregroundStyle(VFColor.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            Button {
                onNext()
            } label: {
                HStack {
                    Text("Zaczynamy")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(VFOutlineButtonStyle(solid: true))
        }
    }
}

// MARK: - Krok 2: Ustawienia

private struct SettingsStepView: View {
    @Binding var didOpenSettings: Bool

    private let steps: [SettingsStep] = [
        .init(number: 1, icon: "gearshape", title: "Otwórz Ustawienia",
              detail: "Ogólne → Klawiatura → Klawiatury → Dodaj nową klawiaturę"),
        .init(number: 2, icon: "keyboard", title: "Wybierz VoiceFlow",
              detail: "Pojawi się na liście klawiatur firm trzecich"),
        .init(number: 3, icon: "mic.badge.plus", title: "Włącz Pełny dostęp",
              detail: "Bez tego mikrofon w klawiaturze nie zadziała — to wymóg systemu iOS, nie nasza decyzja"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("KROK 2 Z 4").vfEyebrow()
                Text("DODAJ KLAWIATURĘ")
                    .font(VFFont.display(22, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(VFColor.text)
                Text("Apple nie pozwala żadnej apce zrobić tego za Ciebie — to dotyczy każdej klawiatury, nie tylko naszej.")
                    .font(VFFont.body(13))
                    .foregroundStyle(VFColor.muted)
            }

            VStack(spacing: 0) {
                ForEach(steps) { s in
                    SettingsStepRow(step: s, isLast: s.number == steps.count)
                }
            }
            .background(VFColor.surface)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))

            Button {
                didOpenSettings = true
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Text("Otwórz Ustawienia")
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                }
            }
            .buttonStyle(VFOutlineButtonStyle(solid: true))

            Text("Gdy wrócisz tutaj z Ustawień, poprowadzimy Cię dalej automatycznie.")
                .font(VFFont.body(12))
                .foregroundStyle(VFColor.faint)
        }
    }
}

private struct SettingsStep: Identifiable {
    let number: Int
    let icon: String
    let title: String
    let detail: String
    var id: Int { number }
}

private struct SettingsStepRow: View {
    let step: SettingsStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(String(format: "%02d", step.number))
                .font(VFFont.mono(12))
                .foregroundStyle(VFColor.faint)
                .frame(width: 26, alignment: .leading)
            Image(systemName: step.icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(VFColor.text)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(VFFont.display(14, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(VFColor.text)
                Text(step.detail)
                    .font(VFFont.body(12.5))
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(VFColor.border).frame(height: 1).padding(.horizontal, 18)
            }
        }
    }
}

// MARK: - Krok 3: przełączenie na klawiaturę VoiceFlow

private struct SwitchKeyboardStepView: View {
    let onDone: () -> Void
    let onSkip: () -> Void
    @State private var practiceText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("KROK 3 Z 4").vfEyebrow()
                Text("PRZEŁĄCZ SIĘ NA VOICEFLOW")
                    .font(VFFont.display(22, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(VFColor.text)
                Text("Stuknij w pole poniżej, żeby wywołać klawiaturę. Przytrzymaj ikonę 🌐 (globus) w lewym dolnym rogu klawiatury i wybierz „VoiceFlow” z listy.")
                    .font(VFFont.body(13))
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Stuknij tutaj", text: $practiceText)
                .focused($focused)
                .font(VFFont.body(15))
                .foregroundStyle(VFColor.text)
                .padding(16)
                .background(VFColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
                .onAppear { focused = true }

            // Apple nie daje API do wykrycia "użytkownik przełączył się na
            // konkretną klawiaturę firmy trzeciej" — jedyna uczciwa opcja to
            // zapytać wprost, z możliwością pominięcia (patrz komentarz w
            // OnboardingView nad `Step`).
            VStack(spacing: 10) {
                Button {
                    onDone()
                } label: {
                    HStack {
                        Text("Zrobione, przełączyłem/am")
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
                .buttonStyle(VFOutlineButtonStyle(solid: true))

                Button {
                    onSkip()
                } label: {
                    Text("Pomiń ten krok")
                        .font(VFFont.body(13))
                        .foregroundStyle(VFColor.faint)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Krok 4: test dyktowania na żywo (NAJWAŻNIEJSZY)

private struct TestDictationStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("KROK 4 Z 4").vfEyebrow()
                Text("PRZETESTUJ DYKTOWANIE")
                    .font(VFFont.display(22, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(VFColor.text)
                Text("Stuknij mikrofon poniżej i powiedz coś krótkiego. Zobaczysz tekst pojawiający się na żywo — to jest dowód, że wszystko działa, nie tylko obietnica.")
                    .font(VFFont.body(13))
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // TO JEST DOKŁADNIE ten sam komponent co zakładka "Dyktuj" w
            // głównej apce (`DictationView`) — jeden mechanizm testowania i
            // fallbacku, nie dwa równoległe. `recordsToHistory: false`, bo
            // to próba, nie treść do zachowania.
            DictationCardView(compact: true, recordsToHistory: false)

            Button {
                onNext()
            } label: {
                HStack {
                    Text("Dalej")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(VFOutlineButtonStyle(solid: true))
        }
    }
}

// MARK: - Krok 5: gotowe

private struct DoneStepView: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(VFColor.text)
                Text("GOTOWE")
                    .font(VFFont.display(28, weight: .extrabold))
                    .textCase(.uppercase)
                    .foregroundStyle(VFColor.text)
                Text("Klawiatura VoiceFlow jest skonfigurowana. Jeśli kiedykolwiek zechcesz sprawdzić jej stan (Pełny dostęp, czy mikrofon działa), zajrzyj do Ustawień w apce.")
                    .font(VFFont.body(14))
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            Button {
                onFinish()
            } label: {
                HStack {
                    Text("Zacznij korzystać")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(VFOutlineButtonStyle(solid: true))
        }
    }
}

// MARK: - Wspólne

private struct StepProgressBar: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Rectangle()
                    .fill(i <= current ? VFColor.text : VFColor.border)
                    .frame(height: 2)
            }
        }
    }
}
