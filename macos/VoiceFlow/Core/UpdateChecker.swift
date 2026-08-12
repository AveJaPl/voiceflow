import AppKit
import Foundation

/// Samo-aktualizacja z GitHub Releases (repo publiczne AveJaPl/voiceflow).
///
/// Kanał: release z tagiem `mac-vX.Y.Z` i assetem `VoiceFlow-mac.zip`
/// (publikowane skryptem `tools/release-mac.sh`). Sprawdzenie przy starcie
/// i co 6 godzin; nowsza wersja jest pobierana, rozpakowywana do
/// `~/Applications/VoiceFlow.app` i apka restartuje się sama — chyba że
/// akurat trwa dyktowanie, wtedy podmiana czeka na najbliższy bezczynny
/// moment. Bez Sparkle'a celowo: jeden plik, zero zależności, a podpis
/// i notaryzacja to na tym etapie nasz własny build z tej maszyny.
@MainActor
final class UpdateChecker {

    static let releasesURL = URL(string: "https://api.github.com/repos/AveJaPl/voiceflow/releases")!
    private static let tagPrefix = "mac-v"
    private static let assetName = "VoiceFlow-mac.zip"
    private static let checkInterval: TimeInterval = 6 * 3600

    /// Zwraca `true`, gdy TERAZ nie wolno podmieniać apki (trwa dyktowanie).
    private let isBusy: () -> Bool
    private var timer: Timer?
    /// Wersja pobrana i zainstalowana na dysku, czekająca na restart.
    private(set) var installedPendingRestart: String?

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        Task { await checkAndInstall() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.checkAndInstall() }
        }
    }

    /// Porównanie wersji „po ludzku": 0.10.0 > 0.9.1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Najnowsza wersja kanału mac z listy release'ów GitHuba (JSON API).
    static func latestMacRelease(in json: Data) -> (version: String, assetURL: URL)? {
        guard let releases = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            return nil
        }
        for release in releases {
            guard let tag = release["tag_name"] as? String, tag.hasPrefix(tagPrefix),
                  (release["draft"] as? Bool) != true,
                  let assets = release["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { continue }
            return (String(tag.dropFirst(tagPrefix.count)), url)
        }
        return nil
    }

    func checkAndInstall() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.releasesURL)
            guard let latest = Self.latestMacRelease(in: data) else {
                DebugLog.write("Update", "brak release'ów kanału mac — nic do roboty")
                return
            }
            let current = Self.currentVersion
            guard Self.isNewer(latest.version, than: current) else {
                DebugLog.write("Update", "wersja \(current) aktualna (najnowsza: \(latest.version))")
                return
            }
            guard installedPendingRestart != latest.version else { return }
            DebugLog.write("Update", "nowa wersja \(latest.version) (mam \(current)) — pobieram")
            try await downloadAndInstall(latest)
        } catch {
            // Brak sieci nie jest błędem apki — sprawdzimy za 6 godzin.
            DebugLog.write("Update", "sprawdzenie aktualizacji nie powiodło się: \(error.localizedDescription)")
        }
    }

    private func downloadAndInstall(_ release: (version: String, assetURL: URL)) async throws {
        let (tmpZip, _) = try await URLSession.shared.download(from: release.assetURL)
        let unpackDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-update-\(release.version)", isDirectory: true)
        _ = try? FileManager.default.removeItem(at: unpackDir)
        try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)

        // `ditto -xk` zamiast ręcznego unzipa — zachowuje podpis i atrybuty
        // bundle'a, dokładnie to, czym pakuje `tools/release-mac.sh`.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", tmpZip.path, unpackDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "ditto -xk zwróciło \(unzip.terminationStatus)"])
        }
        let newApp = unpackDir.appendingPathComponent("VoiceFlow.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw NSError(domain: "Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "w archiwum nie ma VoiceFlow.app"])
        }

        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/VoiceFlow.app")
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: newApp, to: destination)
        installedPendingRestart = release.version
        DebugLog.write("Update", "wersja \(release.version) zainstalowana w \(destination.path) — czekam na moment na restart")
        restartWhenIdle()
    }

    /// Restart w pierwszej bezczynnej chwili — podmiana apki W TRAKCIE
    /// dyktowania ucięłaby wypowiedź w połowie.
    private func restartWhenIdle(attempt: Int = 0) {
        guard installedPendingRestart != nil else { return }
        if isBusy(), attempt < 120 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.restartWhenIdle(attempt: attempt + 1)
            }
            return
        }
        DebugLog.write("Update", "restartuję do nowej wersji")
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/VoiceFlow.app")
        // `open -n` nowej kopii dopiero PO wyjściu tej — odpalamy przez
        // /bin/sh z krótkim sleepem, żeby stary proces zdążył zniknąć.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(destination.path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
