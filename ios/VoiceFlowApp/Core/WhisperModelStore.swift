import Combine
import Foundation
import UIKit
import CoreML
import WhisperKit
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "WhisperModelStore")

/// Downloads and prepares the selected on-device model. Core ML specialization
/// can take minutes on first use; every stage is visible and bounded.
@MainActor
final class WhisperModelStore: ObservableObject {
    static let shared = WhisperModelStore()

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: WhisperModelCatalog.Model
    /// Warianty wspierane na tym urządzeniu wg WhisperKit — do listy w Ustawieniach.
    @Published private(set) var supportedVariants: [String]

    private(set) var pipeline: WhisperKit?
    private var task: Task<Void, Never>?
    private var loadID = UUID()
    private let background = ModelPreparationBackground()
    private var scheduled = false
    var supportsBackgroundPreparation: Bool { background.available }
    @Published private(set) var loadingMessage = "Przygotowuję model"
    @Published private(set) var loadingSeconds = 0
    private var loadingStartedAt: Date?
    private var loadingTimer: Timer?
    private var previousIdleTimerDisabled: Bool?
    private static let loadingTimeout: TimeInterval = 300
    private let defaults: UserDefaults

    static let selectedVariantKey = "voiceflow.ios.whisperModel"
    private static let folderKeyPrefix = "voiceflow.ios.whisperModelFolder."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = WhisperKit.recommendedModels()
        self.supportedVariants = support.supported
        let stored = defaults.string(forKey: Self.selectedVariantKey).flatMap(WhisperModelCatalog.model(variant:))
        self.selected = stored ?? WhisperModelCatalog.defaultModel(supported: support.supported)
    }

    var isReady: Bool { phase == .ready && pipeline != nil }

    /// Modele z katalogu, które mają sens na tym telefonie. `large-v3-turbo`
    /// tylko tam, gdzie WhisperKit go wspiera — na słabszym urządzeniu i tak
    /// by nie wystartował.
    var availableModels: [WhisperModelCatalog.Model] {
        WhisperModelCatalog.all.filter { supportedVariants.contains($0.variant) || $0 == WhisperModelCatalog.base }
    }

    /// Katalog na modele: Application Support, wykluczony z kopii zapasowej —
    /// 632 MB, które da się pobrać ponownie, nie mają czego szukać w iCloud.
    private var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = base
        try? mutable.setResourceValues(values)
        return base
    }

    private func storedFolder(for model: WhisperModelCatalog.Model) -> URL? {
        // iOS may move the app data container when an update is installed.
        let current = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)")
        if FileManager.default.fileExists(atPath: current.appendingPathComponent("config.json").path) {
            return current
        }
        guard let path = defaults.string(forKey: Self.folderKeyPrefix + model.variant),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Sterowanie

    /// Wołane przy starcie apki i po zmianie modelu. Idempotentne: drugi
    /// `prepare()` w trakcie pobierania nic nie zaczyna od nowa.
    func prepare() {
        guard task == nil, !scheduled, !isReady else { return }
        let model = selected
        let id = UUID()
        loadID = id
        scheduled = true
        background.onExpiration = { [weak self] in
            // Foreground work needs no background grant; keep the load running
            // if the user has already returned to the app.
            guard UIApplication.shared.applicationState != .active else { return }
            self?.cancelPreparation(message: "iOS przerwał przygotowanie w tle. Otwórz aplikację i wybierz Spróbuj ponownie.")
        }
        background.run { [weak self] in
            guard let self, self.loadID == id else { return }
            self.scheduled = false
            self.task = Task { [weak self] in
                await self?.download(andLoad: model, id: id)
                if self?.loadID == id {
                    self?.task = nil
                    self?.background.finish(success: self?.isReady == true)
                }
            }
        }
    }

    func select(_ model: WhisperModelCatalog.Model) {
        guard model != selected else { return }
        task?.cancel()
        scheduled = false
        background.finish(success: false)
        finishLoading()
        task = nil
        pipeline = nil
        phase = .idle
        selected = model
        defaults.set(model.variant, forKey: Self.selectedVariantKey)
        prepare()
    }

    private func download(andLoad model: WhisperModelCatalog.Model, id: UUID) async {
        guard loadID == id, !Task.isCancelled else { return }
        let folder: URL
        if let existing = storedFolder(for: model) {
            folder = existing
        } else {
            phase = .downloading(fraction: 0)
            do {
                folder = try await WhisperKit.download(
                    variant: model.variant,
                    downloadBase: downloadBase,
                    progressCallback: { [weak self] progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            guard self?.loadID == id else { return }
                            if case .downloading = self?.phase { self?.phase = .downloading(fraction: fraction) }
                        }
                    }
                )
                guard loadID == id, !Task.isCancelled else { return }
                defaults.set(folder.path, forKey: Self.folderKeyPrefix + model.variant)
            } catch {
                guard loadID == id, !Task.isCancelled else { return }
                log.error("download failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed("Nie udało się pobrać modelu: \(error.localizedDescription)")
                return
            }
        }
        guard loadID == id, !Task.isCancelled else { return }

        phase = .loading
        loadingStartedAt = Date()
        loadingSeconds = 0
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadingTick(id: id) }
        }
        defer { if loadID == id { finishLoading() } }
        do {
            setLoadingStage("Przygotowuję pliki modelu", id: id)
            // On iPhone 16 Pro / iOS 27 the ANE encoder specialization stalled
            // for minutes. CPU encoder + ANE decoder transcribed the 4.29 s
            // Polish fixture in 2.74 s with the same text as Mac turbo.
            let encoderCompute: MLComputeUnits = .cpuOnly
            let pipe = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: downloadBase,
                computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: encoderCompute, textDecoderCompute: .cpuAndNeuralEngine),
                verbose: false, logLevel: .error,
                prewarm: false, load: false, download: false
            ))
            // CPU encoder loading has no ANE specialization to cache. A separate
            // prewarm pass loads and discards the entire encoder, then repeats
            // that expensive work. Load each component once via WhisperKit.
            background.update(step: 1, message: "Ładuję model i słownik językowy")
            setLoadingStage("Ładuję model i słownik językowy", id: id)
            try await pipe.loadModels()
            try Task.checkCancellation()
            guard loadID == id else { return }
            pipeline = pipe
            loadingSeconds = Int(Date().timeIntervalSince(loadingStartedAt ?? Date()))
            phase = .ready
            writeDiagnostic("ready")
            #if DEBUG
            if LaunchOverrides.transcribeFixture { Task { await self.transcribeFixture(pipe) } }
            #endif
            log.info("model \(model.variant, privacy: .public) gotowy po \(self.loadingSeconds) s")
        } catch {
            guard loadID == id, !Task.isCancelled else { return }
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
            // Loading/tokenizer/network errors do not prove damaged weights.
            // Keep the downloaded model and Core ML cache for a safe retry.
            phase = .failed("Nie udało się przygotować modelu. Pliki są zachowane. Spróbuj ponownie lub wybierz mniejszy model. \(error.localizedDescription)")
            writeDiagnostic("failed")
        }
    }

    private func setLoadingStage(_ message: String, id: UUID) {
        guard loadID == id else { return }
        loadingMessage = message
        writeDiagnostic("loading")
    }

    private func loadingTick(id: UUID) {
        guard loadID == id, let started = loadingStartedAt, phase == .loading else { return }
        loadingSeconds = Int(Date().timeIntervalSince(started))
        guard Double(loadingSeconds) >= Self.loadingTimeout else { return }
        cancelPreparation(message: "Przygotowanie przekroczyło 5 minut. Wybierz model base lub spróbuj ponownie. Pobrane pliki zostały zachowane.")
    }

    private func cancelPreparation(message: String) {
        task?.cancel()
        loadID = UUID()
        task = nil
        scheduled = false
        phase = .failed(message)
        writeDiagnostic("interrupted")
        finishLoading()
        background.finish(success: false)
    }

    #if DEBUG
    private func transcribeFixture(_ pipe: WhisperKit) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var results: [[String: Any]] = []
        for name in ["voiceflow-test.wav", "voiceflow-test-2.wav", "voiceflow-test-3.wav"] {
            let path = documents.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            var report: [String: Any] = ["model": selected.variant, "cpuEncoder": true, "file": name]
            do {
                let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path.path)
                let start = Date()
                let text = try await DictationEngine.transcribe(audio, with: pipe, vocabulary: [])
                report["text"] = text
                report["seconds"] = Date().timeIntervalSince(start)
                report["audioSeconds"] = Double(audio.count) / 16000
            } catch { report["error"] = error.localizedDescription }
            results.append(report)
            if let data = try? JSONSerialization.data(withJSONObject: results) {
                try? data.write(to: documents.appendingPathComponent("fixture-results.json"), options: .atomic)
            }
        }
    }
    #endif

    private func finishLoading() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingStartedAt = nil
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }

    private func writeDiagnostic(_ status: String) {
        let object: [String: Any] = ["status": status, "stage": loadingMessage,
            "model": selected.variant, "seconds": loadingSeconds, "cpuEncoder": true, "backgroundSupported": background.available, "applicationState": UIApplication.shared.applicationState.rawValue,
            "at": ISO8601DateFormatter().string(from: Date())]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("model-preparation.json")
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Ponowna próba po błędzie (przycisk w Ustawieniach).
    func retry() {
        guard case .failed = phase else { return }
        phase = .idle
        prepare()
    }
}
