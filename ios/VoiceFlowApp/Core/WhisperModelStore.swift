import Combine
import Foundation
import WhisperKit
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "WhisperModelStore")

/// Cykl życia modelu whisper na telefonie: wybór → pobranie → załadowanie do
/// Core ML → gotowy `WhisperKit`. Jedna instancja na apkę (`shared`), bo model
/// zajmuje setki MB pamięci i ładuje się sekundy — nie ma go po co tworzyć
/// per ekran.
///
/// Zasada „instalujesz i masz wszystko”: przy pierwszym starcie apka SAMA
/// wybiera model pod ten telefon (`WhisperModelCatalog.defaultModel`) i zaczyna
/// pobierać w tle. Dopóki model nie jest gotowy, dyktowanie idzie przez
/// `SFSpeechRecognizer` (patrz `DictationEngine`) — użytkownik nie czeka na
/// nic, tylko dostaje słabszą transkrypcję przez pierwsze minuty.
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
        guard let path = defaults.string(forKey: Self.folderKeyPrefix + model.variant),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Sterowanie

    /// Wołane przy starcie apki i po zmianie modelu. Idempotentne: drugi
    /// `prepare()` w trakcie pobierania nic nie zaczyna od nowa.
    func prepare() {
        guard task == nil, !isReady else { return }
        let model = selected
        task = Task { [weak self] in
            await self?.download(andLoad: model)
            self?.task = nil
        }
    }

    func select(_ model: WhisperModelCatalog.Model) {
        guard model != selected else { return }
        task?.cancel()
        task = nil
        pipeline = nil
        phase = .idle
        selected = model
        defaults.set(model.variant, forKey: Self.selectedVariantKey)
        prepare()
    }

    private func download(andLoad model: WhisperModelCatalog.Model) async {
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
                            if case .downloading = self?.phase { self?.phase = .downloading(fraction: fraction) }
                        }
                    }
                )
                defaults.set(folder.path, forKey: Self.folderKeyPrefix + model.variant)
            } catch {
                guard !Task.isCancelled else { return }
                log.error("download failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed("Nie udało się pobrać modelu: \(error.localizedDescription)")
                return
            }
        }
        guard !Task.isCancelled else { return }

        phase = .loading
        do {
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            guard !Task.isCancelled else { return }
            pipeline = pipe
            phase = .ready
            log.info("model \(model.variant, privacy: .public) gotowy")
        } catch {
            guard !Task.isCancelled else { return }
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
            // Uszkodzone pobranie (przerwane w połowie) — następna próba
            // pobiera od nowa zamiast wiecznie walić głową w ten sam katalog.
            defaults.removeObject(forKey: Self.folderKeyPrefix + model.variant)
            try? FileManager.default.removeItem(at: folder)
            phase = .failed("Nie udało się załadować modelu: \(error.localizedDescription)")
        }
    }

    /// Ponowna próba po błędzie (przycisk w Ustawieniach).
    func retry() {
        guard case .failed = phase else { return }
        phase = .idle
        prepare()
    }
}
