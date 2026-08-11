import SwiftUI

/// Zakładka główna "Dyktuj" — plan B z docs/plans/ios-voiceflow-app.md §3.
/// Cała logika/UI jest w `DictationCardView`, który jest TYM SAMYM
/// komponentem co krok testu dyktowania w onboardingu (`OnboardingView`
/// krok `.testDictation`) — celowo jeden mechanizm, nie dwa równoległe
/// (dopisek Wojtka po teście starej sondy, 2026-08-10).
struct DictationView: View {
    var body: some View {
        DictationCardView(compact: false, recordsToHistory: true)
            .navigationTitle("")
    }
}
