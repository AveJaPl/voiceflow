import AVFoundation
import Combine
import UIKit

/// One explicitly activated audio session; the extension controls utterances.
/// Between utterances no audio is buffered, transcribed, saved or uploaded.
@MainActor
final class KeyboardDictationSession: ObservableObject {
    static let shared = KeyboardDictationSession()
    let engine = DictationEngine()
    @Published private(set) var snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .idle)
    private var timer: Timer?
    private var observer: AnyCancellable?
    private var interruption: NSObjectProtocol?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var sessionStartedAt: Date?
    private var sessionDeadline: Date? {
        guard let sessionStartedAt else { return nil }
        return KeyboardActivityPolicy.deadline(startedAt: sessionStartedAt,
            lastVisibleAt: AppGroup.defaults.object(forKey: KeyboardSessionStore.visibleAtKey) as? Date)
    }

    private init() {
        observer = engine.$state.dropFirst().sink { [weak self] state in self?.changed(state) }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.endSession() }
            }
    }

    func activate(requestID: UUID? = nil) {
        guard UIApplication.shared.applicationState == .active, !engine.isBusy, !engine.microphoneReady else { return }
        sessionStartedAt = Date()
        snapshot = KeyboardSessionSnapshot(id: requestID ?? UUID(), phase: .preparing)
        snapshot.accountKey = AccountSession.shared.accountKey
        startTimer()
        engine.prepareKeyboardMicrophone()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func start(requestID: UUID? = nil) {
        guard !engine.isBusy else { return }
        if !engine.microphoneReady && UIApplication.shared.applicationState != .active { return }
        if sessionStartedAt == nil { sessionStartedAt = Date() }
        snapshot = KeyboardSessionSnapshot(id: requestID ?? UUID(), phase: .preparing)
        snapshot.accountKey = AccountSession.shared.accountKey
        startTimer()
        engine.toggle(keepAudioAlive: true)
    }

    func stop() {
        guard engine.state == .listening else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.cancel()
                    self.snapshot.phase = .error
                    self.snapshot.text = "iOS przerwał rozpoznawanie. Spróbuj krótszej wypowiedzi."
                    self.publish()
                }
            }
        }
        engine.stop()
    }

    func endSession() {
        stop()
        engine.endKeyboardSession()
        sessionStartedAt = nil
        publish()
        if !engine.isBusy { timer?.invalidate() }
    }

    func cancel() {
        engine.cancel()
        sessionStartedAt = nil
        timer?.invalidate()
        snapshot.phase = .idle
        snapshot.text = ""
        snapshot.resultAt = nil
        publish()
        finishBackgroundTask()
    }

    private func tick() {
        if let deadline = sessionDeadline, Date() >= deadline { endSession() }
        if AppGroup.defaults.bool(forKey: KeyboardSessionStore.endKey) {
            AppGroup.defaults.removeObject(forKey: KeyboardSessionStore.endKey)
            endSession()
        }
        if let data = AppGroup.defaults.data(forKey: KeyboardSessionStore.startKey) {
            AppGroup.defaults.removeObject(forKey: KeyboardSessionStore.startKey)
            if let request = try? JSONDecoder().decode(KeyboardSessionRequest.self, from: data),
               request.isFresh(at: Date()), engine.microphoneReady { start(requestID: request.id) }
        }
        if AppGroup.defaults.string(forKey: KeyboardSessionStore.stopKey) == snapshot.id.uuidString {
            AppGroup.defaults.removeObject(forKey: KeyboardSessionStore.stopKey)
            stop()
        }
        publish()
    }

    private func changed(_ state: DictationEngine.State) {
        switch state {
        case .idle:
            if !engine.liveText.isEmpty {
                snapshot.phase = .result
                snapshot.text = engine.liveText
                snapshot.resultAt = Date()
            } else { snapshot.phase = .idle }
            if !engine.microphoneReady { timer?.invalidate(); sessionStartedAt = nil }
            finishBackgroundTask()
        case .requestingPermission: snapshot.phase = .preparing
        case .listening: snapshot.phase = .recording
        case .transcribing: snapshot.phase = .processing
        case .error(let message):
            snapshot.phase = .error
            snapshot.text = message
            if !engine.microphoneReady { timer?.invalidate(); sessionStartedAt = nil }
            finishBackgroundTask()
        }
        publish()
    }

    private func publish() {
        snapshot.level = engine.audioLevel
        snapshot.updatedAt = Date()
        snapshot.microphoneReady = engine.microphoneReady
        snapshot.expiresAt = sessionDeadline
        KeyboardSessionStore.write(snapshot)
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
