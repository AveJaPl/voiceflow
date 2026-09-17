import SwiftUI

struct KeyboardHandoffView: View {
    var requestID: UUID? = nil
    var onClose: (() -> Void)?
    @ObservedObject private var session = KeyboardDictationSession.shared
    @ObservedObject private var models = WhisperModelStore.shared

    var body: some View {
        VStack(spacing: 28) {
            HStack { Spacer(); Button("Zamknij") { if session.engine.isBusy { session.cancel() }; onClose?() } }
            Spacer()
            VoiceRecordingPill(level: session.snapshot.level, label: title, active: session.snapshot.phase == .recording)
            if !models.isReady { ModelStatusView(models: models) }
            Text(title).font(.system(size: 28, weight: .semibold))
            Text(detail).font(.system(size: 15)).foregroundStyle(VFColor.muted)
                .multilineTextAlignment(.center)
            if session.snapshot.phase == .recording {
                Button("Koniec dyktowania") { session.stop() }.buttonStyle(VFOutlineButtonStyle(solid: true))
            }
            if session.snapshot.phase == .result {
                ScrollView { Text(session.snapshot.text).textSelection(.enabled) }.frame(maxHeight: 180)
                Button("Kopiuj tekst") { UIPasteboard.general.string = session.snapshot.text }
                    .buttonStyle(VFOutlineButtonStyle())
            }
            if session.snapshot.phase == .error || session.snapshot.phase == .idle {
                Button("Start dyktowania") { session.start(requestID: requestID) }.buttonStyle(VFOutlineButtonStyle(solid: true))
                    .disabled(!models.isReady)
            }
            Text("Mikrofon wyłączy się 30 sekund po schowaniu klawiatury. Na pierwszy powrót do klawiatury masz minutę. Pomiędzy dyktowaniami dźwięk nie jest zapisywany ani rozpoznawany.")
                .font(.system(size: 12)).foregroundStyle(VFColor.muted).multilineTextAlignment(.center)
            Button("Wyłącz sesję mikrofonu") { session.endSession() }
                .font(.system(size: 13)).foregroundStyle(VFColor.muted)
            Spacer()
        }
        .padding(28).background(VFColor.background).foregroundStyle(VFColor.text)
        .onAppear { if models.isReady { session.start(requestID: requestID) } }
        .onChange(of: models.isReady) { _, ready in
            if ready, !session.engine.isBusy { session.start(requestID: requestID) }
        }
    }
    private var title: String {
        switch session.snapshot.phase {
        case .recording: "Słucham"
        case .processing: "Domykam…"
        case .result: "Tekst gotowy"
        case .error: "Jeszcze chwila"
        default: "Przygotowuję…"
        }
    }
    private var detail: String {
        switch session.snapshot.phase {
        case .recording: "Wróć do poprzedniej aplikacji gestem na dolnym pasku. Mów dalej i zakończ dyktowanie na klawiaturze VoiceFlow."
        case .result: KeyboardSessionStore.automaticallyInsert ? "Wróć do pola, z którego zaczęło się dyktowanie. Możesz też wstawić tekst przyciskiem na klawiaturze." : "Wróć do klawiatury VoiceFlow i wybierz Wklej tekst."
        case .error: session.snapshot.text
        case .processing: "Nagrywanie zakończone. Model przetwarza wypowiedź na telefonie."
        default: "Model i mikrofon muszą być gotowe przed rozpoczęciem."
        }
    }
}
