import UIKit
import SwiftUI
import Combine

@MainActor
final class KeyboardPanelModel: ObservableObject {
    @Published var phase: KeyboardSessionSnapshot.Phase = .idle
    @Published var level: Float = 0
    @Published var message = "Polski i angielski · na urządzeniu"
    @Published var hasResult = false
    @Published var fullAccess = false
    @Published var automatic = KeyboardSessionStore.automaticallyInsert
}

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardPanelModel()
    private var timer: Timer?
    private var originDocument: UUID?
    private var requestedAt: Date?
    private var displayedSession: UUID?
    private var host: UIHostingController<VoiceKeyboardPanel>?

    override func viewDidLoad() {
        super.viewDidLoad()
        AppGroup.defaults.set(true, forKey: AppGroupKeys.keyboardHasLaunched)
        let content = VoiceKeyboardPanel(model: model, start: { [weak self] in self?.rememberOrigin() },
            stop: { [weak self] in self?.stop() }, insert: { [weak self] in self?.insert() },
            next: { [weak self] in self?.advanceToNextInputMode() },
            delete: { [weak self] in self?.textDocumentProxy.deleteBackward() })
        let host = UIHostingController(rootView: content)
        self.host = host
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 238)
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.fullAccess = hasFullAccess
        AppGroup.defaults.set(hasFullAccess, forKey: AppGroupKeys.keyboardHasFullAccessObserved)
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
    }

    private func rememberOrigin() {
        originDocument = textDocumentProxy.documentIdentifier
        requestedAt = Date()
        model.message = "Jeśli iOS nie otworzy aplikacji, otwórz VoiceFlow i wybierz Dyktuj teraz."
    }

    private func refresh() {
        guard hasFullAccess, let state = KeyboardSessionStore.read() else { return }
        displayedSession = state.id
        let active = [.preparing, .recording, .processing].contains(state.phase)
        model.phase = active && !state.isLive(at: Date()) ? .error : state.phase
        model.level = model.phase == .recording ? state.level : 0
        model.hasResult = state.phase == .result && !state.text.isEmpty
            && AppGroup.defaults.string(forKey: KeyboardSessionStore.consumedKey) != state.id.uuidString
        if active && !state.isLive(at: Date()) {
            model.message = "Sesja została przerwana. Otwórz VoiceFlow, aby zacząć ponownie."
        } else if state.phase == .error { model.message = state.text }
        else if state.phase == .recording { model.message = "Słucham · zakończ, gdy skończysz mówić" }
        else if state.phase == .processing { model.message = "Rozpoznaję na telefonie…" }
        if model.hasResult, model.automatic,
           state.mayAutoInsert(now: Date(), requestedAt: requestedAt,
               sameDocument: originDocument == textDocumentProxy.documentIdentifier, consumed: false) {
            insert()
        }
    }

    private func stop() {
        guard let id = displayedSession, model.phase == .recording else { return }
        AppGroup.defaults.set(id.uuidString, forKey: KeyboardSessionStore.stopKey)
        model.message = "Kończę nagrywanie…"
    }

    private func insert() {
        guard hasFullAccess, let state = KeyboardSessionStore.read(), state.phase == .result,
              !state.text.isEmpty,
              AppGroup.defaults.string(forKey: KeyboardSessionStore.consumedKey) != state.id.uuidString else { return }
        textDocumentProxy.insertText(state.text)
        AppGroup.defaults.set(state.id.uuidString, forKey: KeyboardSessionStore.consumedKey)
        requestedAt = nil
        model.hasResult = false
        model.message = "Wstawiono tekst"
    }
}

private struct VoiceKeyboardPanel: View {
    @ObservedObject var model: KeyboardPanelModel
    let start: () -> Void
    let stop: () -> Void
    let insert: () -> Void
    let next: () -> Void
    let delete: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("VoiceFlow").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Automatycznie", isOn: $model.automatic).font(.system(size: 12)).fixedSize()
                    .onChange(of: model.automatic) { _, value in
                        AppGroup.defaults.set(value, forKey: KeyboardSessionStore.automaticInsertionKey)
                    }
            }
            if model.phase == .recording {
                VoiceWaveform(level: model.level).frame(width: 150, height: 24)
            } else {
                Image(systemName: model.hasResult ? "checkmark.circle" : "waveform")
                    .frame(height: 24).accessibilityHidden(true)
            }
            Text(model.fullAccess ? model.message : "Włącz Pełny dostęp w Ustawieniach klawiatury VoiceFlow.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                .frame(height: 32)
            HStack(spacing: 12) {
                Button(action: next) { Image(systemName: "globe").frame(width: 44, height: 44) }
                    .accessibilityLabel("Zmień klawiaturę")
                Button {
                    if model.phase == .recording { stop() }
                    else if model.hasResult { insert() }
                    else {
                        start()
                        openURL(URL(string: "voiceflow://dictate")!) { accepted in
                            if !accepted { model.message = "Otwórz VoiceFlow i wybierz Dyktuj teraz. Potem wróć tutaj." }
                        }
                    }
                } label: {
                    Label(model.phase == .recording ? "Koniec dyktowania" : model.hasResult ? "Wstaw tekst" : "Start dyktowania",
                          systemImage: model.phase == .recording ? "stop.fill" : model.hasResult ? "text.insert" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white, in: Capsule()).foregroundStyle(.black)
                }
                .disabled(!model.fullAccess || model.phase == .processing || model.phase == .preparing)
                Button(action: delete) { Image(systemName: "delete.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Usuń znak")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.05, blue: 0.06)).foregroundStyle(.white)
    }
}
