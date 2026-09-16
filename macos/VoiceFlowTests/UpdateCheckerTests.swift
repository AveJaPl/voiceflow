import XCTest
@testable import VoiceFlow

final class UpdateCheckerTests: XCTestCase {
    func testIgnoresDraftsPrereleasesAndOtherPlatforms() async throws {
        let json = Data("""
        [
          {"tag_name":"mac-v9.0.0","draft":true,"assets":[{"name":"VoiceFlow-mac.zip","browser_download_url":"https://example.com/draft.zip"}]},
          {"tag_name":"mac-v8.0.0","prerelease":true,"assets":[{"name":"VoiceFlow-mac.zip","browser_download_url":"https://example.com/beta.zip"}]},
          {"tag_name":"v7.0.0","assets":[{"name":"voiceflow-install.bat"}]},
          {"tag_name":"mac-v0.7.1","assets":[{"name":"VoiceFlow-mac.zip","browser_download_url":"https://example.com/stable.zip"}]}
        ]
        """.utf8)
        try await MainActor.run {
            XCTAssertEqual(UpdateChecker.latestMacRelease(in: json)?.version, "0.7.1")
            XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
            XCTAssertFalse(UpdateChecker.isNewer("0.7.1", than: "0.7.1"))
        }
    }

    func testRejectsMislabeledReleaseAndOtherBundle() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        func write(version: String, bundle: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": bundle, "CFBundleShortVersionString": version
            ], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try write(version: "0.6.0", bundle: "io.github.avejapl.voiceflow")
        try await MainActor.run {
            XCTAssertThrowsError(try UpdateChecker.verifyReleaseMetadata(at: app, version: "0.7.0"))
        }
        try write(version: "0.7.1", bundle: "another.app")
        try await MainActor.run {
            XCTAssertThrowsError(try UpdateChecker.verifyReleaseMetadata(at: app, version: "0.7.1"))
        }
        try write(version: "0.7.1", bundle: "io.github.avejapl.voiceflow")
        try await MainActor.run {
            XCTAssertNoThrow(try UpdateChecker.verifyReleaseMetadata(at: app, version: "0.7.1"))
        }
    }
}
