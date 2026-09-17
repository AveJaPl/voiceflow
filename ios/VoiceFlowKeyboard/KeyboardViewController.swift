import UIKit
import SwiftUI
import Combine

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardPanelModel()
    private var timer: Timer?
    private var draft = KeyboardDraft.load()
    private var heightConstraint: NSLayoutConstraint?
    private var editObserver: AnyCancellable?
    private var lastPresenceWrite = Date.distantPast
    private var originDocument: UUID?
    private var requestedAt: Date?
    private var requestedSession: UUID?
    private var awaitingSession: UUID?
    private var displayedSession: UUID?
    private var host: UIHostingController<VoiceKeyboardPanel>?

    override func loadView() {
        let keyboard = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        keyboard.allowsSelfSizing = true
        inputView = keyboard
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.result = draft?.text ?? ""
        AppGroup.defaults.set(true, forKey: AppGroupKeys.keyboardHasLaunched)
        let content = VoiceKeyboardPanel(model: model,
            start: { [weak self] in self?.start() }, stop: { [weak self] in self?.stop() },
            insert: { [weak self] in self?.insert() },
            end: { AppGroup.defaults.set(true, forKey: KeyboardSessionStore.endKey) },
            next: { [weak self] in self?.advanceToNextInputMode() },
            clear: { [weak self] in self?.clearDraft() },
            changed: { [weak self] text in self?.updateDraft(text) },
            save: { [weak self] in self?.saveDraftHistory() })
        let host = UIHostingController(rootView: content)
        self.host = host
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        let height = view.heightAnchor.constraint(equalToConstant: 260)
        height.priority = .defaultHigh
        heightConstraint = height
        editObserver = model.$isEditing.dropFirst().sink { [weak self] editing in
            self?.heightConstraint?.constant = editing ? 390 : 260
        }
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        overrideUserInterfaceStyle = textDocumentProxy.keyboardAppearance == .dark ? .dark :
            textDocumentProxy.keyboardAppearance == .light ? .light : .unspecified
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
        if model.isEditing { saveDraftHistory() }
    }

    private func start() {
        guard hasFullAccess else { return }
        guard let state = KeyboardSessionStore.read(), state.canStartInPlace(at: Date()) else {
            // Activation does not start an utterance or discard the last draft.
            awaitingSession = nil
            requestedAt = nil
            requestedSession = nil
            model.openURL = URL(string: "voiceflow://dictate?session=\(UUID().uuidString)")
            model.message = "Włącz VoiceFlow, wróć tutaj i kliknij Nowe dyktowanie."
            return
        }
        let request = KeyboardSessionRequest(id: UUID(), issuedAt: Date())
        originDocument = textDocumentProxy.documentIdentifier
        requestedAt = request.issuedAt
        requestedSession = request.id
        awaitingSession = request.id
        model.isEditing = false
        model.phase = .preparing
        if let data = try? JSONEncoder().encode(request) {
            AppGroup.defaults.set(data, forKey: KeyboardSessionStore.startKey)
        }
        model.message = "Zaczynam…"
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
        if state.phase == .result, draft?.sessionID != state.id {
            draft = KeyboardDraft(sessionID: state.id, text: state.text, accountKey: state.accountKey)
            // The original utterance is already in history; only edited versions
            // need a separate local entry.
            let revision = draft?.revision
            draft?.savedRevision = revision
            draft?.save()
        }
        if state.phase == .recording || state.phase == .processing {
            model.result = ""
        } else if let draft {
            model.result = draft.text
        }
        model.consumed = AppGroup.defaults.string(forKey: KeyboardSessionStore.consumedKey) == state.id.uuidString
        if active && !state.isLive(at: Date()) {
            model.message = "Sesja została przerwana. Włącz ją ponownie w VoiceFlow."
        } else {
            switch state.phase {
            case .recording: model.message = "Słucham"
            case .processing: model.message = "Domykam…"
            case .result: model.message = model.result.isEmpty ? "Gotowy na kolejne dyktowanie" : "Tekst gotowy"
            case .error: model.message = state.text
            default: model.message = model.ready ? "Gotowy na kolejne dyktowanie" : "Włącz sesję klawiatury w VoiceFlow"
            }
        }
        if model.automatic, state.id == requestedSession,
           state.mayAutoInsert(now: Date(), requestedAt: requestedAt,
               sameDocument: originDocument == textDocumentProxy.documentIdentifier, consumed: model.consumed) {
            insert(automatic: true)
        }
    }

    private func stop() {
        guard let id = displayedSession, model.phase == .recording else { return }
        AppGroup.defaults.set(id.uuidString, forKey: KeyboardSessionStore.stopKey)
        model.message = "Domykam…"
    }

    private func updateDraft(_ text: String) {
        if draft == nil {
            let state = KeyboardSessionStore.read()
            draft = KeyboardDraft(sessionID: state?.id ?? UUID(), text: "", accountKey: state?.accountKey)
        }
        draft?.replace(with: text)
        draft?.save()
        model.result = text
        suppressAutomaticInsertion()
    }

    private func clearDraft() {
        updateDraft("")
        model.phase = .idle
    }

    private func suppressAutomaticInsertion() {
        if let id = draft?.sessionID { AppGroup.defaults.set(id.uuidString, forKey: KeyboardSessionStore.consumedKey) }
        requestedAt = nil
        requestedSession = nil
    }

    private func saveDraftHistory() {
        guard var draft, draft.needsHistorySave else { return }
        let entry = DictationEntry(id: draft.revision, text: draft.text, source: .keyboard, accountKey: draft.accountKey)
        if !DictationHistoryStore.load().contains(where: { $0.id == entry.id }) { DictationHistoryStore.append(entry) }
        draft.savedRevision = draft.revision
        draft.save()
        self.draft = draft
    }

    private func insert(automatic: Bool = false) {
        guard hasFullAccess, let draft, draft.canInsertManually else { return }
        if automatic, AppGroup.defaults.string(forKey: KeyboardSessionStore.consumedKey) == draft.sessionID.uuidString { return }
        // Manual insertion is intentionally repeatable, including into a new
        // document. Only automatic insertion is consumed once per session.
        textDocumentProxy.insertText(draft.text)
        saveDraftHistory()
        suppressAutomaticInsertion()
        model.consumed = true
        model.message = "Tekst gotowy"
    }
}
