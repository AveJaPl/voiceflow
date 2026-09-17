#if DEBUG
import SwiftUI

/// Renders the real keyboard panel with synthetic levels; never opens the mic.
struct KeyboardPreviewView: View {
    @StateObject private var model = KeyboardPanelModel()
    var body: some View {
        VStack {
            Text("Podgląd klawiatury · bez mikrofonu").font(.caption).foregroundStyle(.secondary)
            Spacer()
            VoiceKeyboardPanel(model: model,
                start: { model.result = ""; model.phase = .recording; model.level = 0.04; model.message = "Słucham" },
                stop: { model.phase = .processing; model.level = 0; model.message = "Domykam…" },
                insert: { model.consumed = true }, end: { model.ready = false }, next: {})
                .frame(height: 312)
        }
        .background(Color(white: 0.12))
        .onAppear {
            model.fullAccess = true
            model.ready = true
            model.phase = .result
            model.result = String(repeating: "Spotkanie z Bartoszem odbędzie się w czwartek o 15:30. Przygotuj ofertę dla Programo i wyślij ją do Marka. ", count: 5)
        }
    }
}
#endif
