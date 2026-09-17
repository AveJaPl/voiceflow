import BackgroundTasks
import UIKit

/// User-started model preparation may continue after leaving the app on iOS 26+.
@MainActor
final class ModelPreparationBackground {
    private static let identifier = "io.github.avejapl.voiceflow.ios.prepareModel"
    private var active: BGTask?
    private var work: (() -> Void)?
    var onExpiration: (() -> Void)?
    private(set) var available = false

    init() {
        if #available(iOS 26.0, *) {
            available = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
                Task { @MainActor in
                    guard let self, let work = self.work else { task.setTaskCompleted(success: false); return }
                    self.work = nil
                    self.active = task
                    if let continuous = task as? BGContinuedProcessingTask {
                        continuous.progress.totalUnitCount = 5
                    }
                    task.expirationHandler = { [weak self] in
                        Task { @MainActor in self?.onExpiration?(); self?.finish(success: false) }
                    }
                    work()
                }
            }
        }
    }

    func run(_ work: @escaping () -> Void) {
        finish(success: false)
        if #available(iOS 26.0, *), available {
            self.work = work
            let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier,
                title: "Przygotowanie VoiceFlow", subtitle: "Pobieram i przygotowuję model dyktowania")
            request.strategy = .fail
            do { try BGTaskScheduler.shared.submit(request); return }
            catch { self.work = nil; available = false }
        }
        work()
    }

    func update(step: Int, message: String) {
        if #available(iOS 26.0, *), let task = active as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(step)
            task.updateTitle("Przygotowanie VoiceFlow", subtitle: message)
        }
    }

    func finish(success: Bool) {
        if #available(iOS 26.0, *) {
            if work != nil { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
            if let task = active as? BGContinuedProcessingTask, success {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
        }
        work = nil
        active?.setTaskCompleted(success: success)
        active = nil
    }
}
