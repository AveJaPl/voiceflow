import AVFoundation
import Combine
import UIKit

/// The app owns audio. The extension only reads levels/results and requests stop.
@MainActor
final class KeyboardDictationSession: ObservableObject {
    static let shared = KeyboardDictationSession()
    let engine = DictationEngine()
    @Published private(set) var snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .idle)
    private var timer: Timer?
    private var observer: AnyCancellable?
    private var interruption: NSObjectProtocol?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        observer = engine.$state.dropFirst().sink { [weak self] state in self?.changed(state) }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.stop() }
            }
    }

    func start() {
        guard !engine.isBusy else { return }
        snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .preparing)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        engine.toggle()
    }

    func stop() {
        guard engine.state == .listening else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.engine.cancel()
                self.snapshot.phase = .error
                self.snapshot.text = "iOS przerwał rozpoznawanie. Spróbuj krótszej wypowiedzi."
                self.publish()
                self.finishBackgroundTask()
            }
        }
        engine.toggle()
    }

    func cancel() {
        engine.cancel()
        timer?.invalidate()
        snapshot.phase = .idle
        snapshot.text = ""
        publish()
        finishBackgroundTask()
    }

    private func tick() {
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
            } else { snapshot.phase = .idle }
            timer?.invalidate()
            finishBackgroundTask()
        case .requestingPermission: snapshot.phase = .preparing
        case .listening: snapshot.phase = .recording
        case .transcribing: snapshot.phase = .processing
        case .error(let message):
            snapshot.phase = .error
            snapshot.text = message
            timer?.invalidate()
            finishBackgroundTask()
        }
        publish()
    }

    private func publish() {
        snapshot.level = engine.audioLevel
        snapshot.updatedAt = Date()
        KeyboardSessionStore.write(snapshot)
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
