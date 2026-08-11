import SwiftUI

/// Ekran pokazywany, gdy apka jest otwarta z klawiatury
/// (`voiceflow://dictate`, patrz `VoiceFlowApp.swift` `.onOpenURL` i
/// docs/plans/ios-voiceflow-app.md §7 — PIVOT #2). Dwa stany:
///   1. Nagrywanie — TEN SAM `DictationCardView` co zakładka "Dyktuj" i test
///      onboardingu (Wojtek wprost poprosił o jeden mechanizm, nie trzy
///      równoległe), ale `autoStart: true` — user kliknął mikrofon W
///      KLAWIATURZE, nie musi kliknąć drugi raz tutaj.
///   2. Po zakończeniu — `HandoffCompleteView`: tekst już czeka w App Group
///      na klawiaturę, user musi tylko przesunąć z powrotem (gest systemowy,
///      dokładnie jak u Wisprа — to nie nasz wymysł, jedyny sposób jaki iOS
///      daje).
struct KeyboardHandoffView: View {
    @State private var isDone = false

    var body: some View {
        Group {
            if isDone {
                HandoffCompleteView()
            } else {
                DictationCardView(compact: false, recordsToHistory: true, autoStart: true) { finalText in
                    AppGroup.defaults.set(finalText, forKey: AppGroupKeys.pendingInsertText)
                    AppGroup.defaults.set(Date(), forKey: AppGroupKeys.pendingInsertAt)
                    withAnimation(.easeOut(duration: 0.25)) { isDone = true }
                }
            }
        }
    }
}

private struct HandoffCompleteView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(VFColor.text)

            VStack(spacing: 10) {
                Text("GOTOWE")
                    .font(VFFont.display(26, weight: .extrabold))
                    .textCase(.uppercase)
                    .tracking(-0.5)
                    .foregroundStyle(VFColor.text)
                Text("Wróć do poprzedniej aplikacji — tekst wstawi się sam.")
                    .font(VFFont.body(14))
                    .foregroundStyle(VFColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(VFColor.faint)
                Text("Przesuń palcem od dolnej krawędzi ekranu")
                    .font(VFFont.body(12.5))
                    .foregroundStyle(VFColor.faint)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VFColor.background)
    }
}
