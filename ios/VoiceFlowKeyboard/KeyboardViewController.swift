import UIKit
import SwiftUI
import Combine

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardPanelModel()
    private var timer: Timer?
    private var lastPresenceWrite = Date.distantPast
    private var originDocument: UUID?
    private var requestedAt: Date?
    private var requestedSession: UUID?
    private var awaitingSession: UUID?
    private var displayedSession: UUID?
    private var host: UIHostingController<VoiceKeyboardPanel>?

    override func viewDidLoad() {
        super.viewDidLoad()
        AppGroup.defaults.set(true, forKey: AppGroupKeys.keyboardHasLaunched)
        let content = VoiceKeyboardPanel(model: model,
            start: { [weak self] in self?.start() }, stop: { [weak self] in self?.stop() },
            insert: { [weak self] in self?.insert() },
            end: { AppGroup.defaults.set(true, forKey: KeyboardSessionStore.endKey) },
            next: { [weak self] in self?.advanceToNextInputMode() })
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
            view.heightAnchor.constraint(equalToConstant: 312)
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.fullAccess = hasFullAccess
        model.needsGlobe = needsInputModeSwitchKey
        AppGroup.defaults.set(hasFullAccess, forKey: AppGroupKeys.keyboardHasFullAccessObserved)
        timer?.invalidate()
        refresh()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
    }

    private func start() {
        guard hasFullAccess else { return }
        let request = KeyboardSessionRequest(id: UUID(), issuedAt: Date())
        originDocument = textDocumentProxy.documentIdentifier
        requestedAt = request.issuedAt
        requestedSession = request.id
        awaitingSession = request.id
        model.result = ""
        model.consumed = false
        model.phase = .preparing
        if let state = KeyboardSessionStore.read(), state.canStartInPlace(at: Date()) {
            if let data = try? JSONEncoder().encode(request) {
                AppGroup.defaults.set(data, forKey: KeyboardSessionStore.startKey)
            }
            model.message = "Zaczynam…"
        } else {
            model.openURL = URL(string: "voiceflow://dictate?session=\(request.id.uuidString)")
            model.message = "Uruchom sesję w VoiceFlow. Potem możesz dyktować tutaj bez przełączania aplikacji."
        }
    }

    private func refresh() {
        if hasFullAccess, Date().timeIntervalSince(lastPresenceWrite) >= 1 {
            lastPresenceWrite = Date()
            AppGroup.defaults.set(lastPresenceWrite, forKey: KeyboardSessionStore.visibleAtKey)
        }
        model.automatic = KeyboardSessionStore.automaticallyInsert
        guard hasFullAccess, let state = KeyboardSessionStore.read() else { return }
        model.ready = state.canStartInPlace(at: Date())
        if let awaitingSession, state.id != awaitingSession {
            if let requestedAt, Date().timeIntervalSince(requestedAt) > 5 {
                self.awaitingSession = nil
                model.phase = .idle
                model.message = "Sesja nie odpowiedziała. Włącz ją ponownie w VoiceFlow."
                model.ready = false
            }
            return
        }
        awaitingSession = nil
        displayedSession = state.id
        let active = [.preparing, .recording, .processing].contains(state.phase)
        model.phase = active && !state.isLive(at: Date()) ? .error : state.phase
        model.level = model.phase == .recording ? state.level : 0
        model.result = state.phase == .result ? state.text : ""
        model.consumed = AppGroup.defaults.string(forKey: KeyboardSessionStore.consumedKey) == state.id.uuidString
        if active && !state.isLive(at: Date()) {
            model.message = "Sesja została przerwana. Włącz ją ponownie w VoiceFlow."
        } else {
            switch state.phase {
            case .recording: model.message = "Słucham"
            case .processing: model.message = "Domykam…"
            case .result: model.message = model.consumed ? "Wklejono" : "Tekst gotowy"
            case .error: model.message = state.text
            default: model.message = model.ready ? "Gotowy na kolejne dyktowanie" : "Włącz sesję klawiatury w VoiceFlow"
            }
        }
        if model.automatic, state.id == requestedSession,
           state.mayAutoInsert(now: Date(), requestedAt: requestedAt,
               sameDocument: originDocument == textDocumentProxy.documentIdentifier, consumed: model.consumed) {
            insert()
        }
    }

    private func stop() {
        guard let id = displayedSession, model.phase == .recording else { return }
        AppGroup.defaults.set(id.uuidString, forKey: KeyboardSessionStore.stopKey)
        model.message = "Domykam…"
    }

    private func insert() {
        guard hasFullAccess, let state = KeyboardSessionStore.read(), state.phase == .result,
              !state.text.isEmpty,
              AppGroup.defaults.string(forKey: KeyboardSessionStore.consumedKey) != state.id.uuidString else { return }
        // insertText replaces the host's selection or inserts at its caret.
        textDocumentProxy.insertText(state.text)
        AppGroup.defaults.set(state.id.uuidString, forKey: KeyboardSessionStore.consumedKey)
        requestedAt = nil
        requestedSession = nil
        model.consumed = true
        model.message = "Wklejono"
    }
}
