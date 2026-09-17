import Foundation
import XCTest

private final class MemoryCredentials: RemoteCredentialStoring {
    var value: RemoteCredentials?
    init(_ value: RemoteCredentials? = nil) { self.value = value }
    func load() -> RemoteCredentials? { value }
    func save(_ credentials: RemoteCredentials) { value = credentials }
    func clear() { value = nil }
}

private final class AccountStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class AccountSyncTests: XCTestCase {
    private let owner = RemoteCredentials(host: AccountAPI.defaultHost, token: "synthetic-a")
    private let other = RemoteCredentials(host: AccountAPI.defaultHost, token: "synthetic-b")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "VoiceFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountStub.self]
        AccountAPI.session = URLSession(configuration: config)
    }
    override func tearDown() async throws {
        AccountAPI.session.invalidateAndCancel()
        AccountAPI.session = .shared
        defaults.removePersistentDomain(forName: suite)
        AccountStub.handler = nil
    }

    func testAccountEndpointsRejectInsecureOrEmbeddedCredentials() throws {
        XCTAssertEqual(try AccountAPI.endpoint(host: "wss://example.com/", path: "/history").absoluteString, "https://example.com/history")
        for host in ["http://example.com", "ws://example.com", "https://user:secret@example.com", "https://example.com?x=1", "https://example.com/api"] {
            XCTAssertThrowsError(try AccountAPI.endpoint(host: host, path: "/history"))
        }
    }

    func testVocabularyResponseDoesNotOverwriteLocalAnonymousWords() async {
        defaults.set(["Local"], forKey: "voiceflow.customVocabulary")
        AccountStub.handler = { req in
            (200, req.url!.path == "/vocabulary" ? "{\"vocabulary\":[\"MacWord\"]}" : "{\"entries\":[]}")
        }
        let account = AccountSession(store: MemoryCredentials(owner), defaults: defaults)
        await account.refresh()
        XCTAssertEqual(account.vocabulary, ["MacWord"])
        XCTAssertEqual(defaults.stringArray(forKey: "voiceflow.customVocabulary"), ["Local"])
        account.updateCredentials(nil)
        XCTAssertEqual(account.vocabulary, ["Local"])
        XCTAssertTrue(account.history.isEmpty)
    }

    func testUploadBelongsToAccountAtRecordingTime() async {
        var postCount = 0
        AccountStub.handler = { req in
            if req.httpMethod == "POST" { postCount += 1 }
            return (200, req.url!.path == "/vocabulary" ? "{\"vocabulary\":[]}" : "{\"entries\":[]}")
        }
        let account = AccountSession(store: MemoryCredentials(other), defaults: defaults)
        account.record(DictationEntry(text: "Synthetic A", source: .containerApp, accountKey: AccountSession.key(owner)), duration: 1, credentials: owner)
        await account.refresh()
        XCTAssertEqual(postCount, 0)
        XCTAssertNotNil(defaults.data(forKey: "account.uploads.\(AccountSession.key(owner))"))
    }

    func testAmbiguousPostIsNotRepeatedOnRefresh() async {
        let entry = DictationEntry(text: "Synthetic", source: .containerApp, accountKey: AccountSession.key(owner))
        let queue = [AccountSession.Upload(entry: entry, duration: 1)]
        defaults.set(try! JSONEncoder().encode(queue), forKey: "account.uploads.\(AccountSession.key(owner))")
        var posts = 0
        AccountStub.handler = { req in
            if req.httpMethod == "POST" { posts += 1; throw URLError(.networkConnectionLost) }
            return (200, req.url!.path == "/vocabulary" ? "{\"vocabulary\":[]}" : "{\"entries\":[]}")
        }
        let account = AccountSession(store: MemoryCredentials(owner), defaults: defaults)
        await account.refresh()
        await account.refresh()
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(account.status.contains("potwierdzenie"))
    }

    func testAmbiguousPostCanBeReconciledWithoutAnotherWrite() async {
        let entry = DictationEntry(text: "Synthetic", source: .containerApp, accountKey: AccountSession.key(owner))
        let key = "account.uploads.\(AccountSession.key(owner))"
        defaults.set(try! JSONEncoder().encode([AccountSession.Upload(entry: entry, duration: 1, uncertain: true)]), forKey: key)
        var posts = 0
        AccountStub.handler = { req in
            if req.httpMethod == "POST" { posts += 1 }
            if req.url!.path == "/vocabulary" { return (200, "{\"vocabulary\":[]}") }
            return (200, "{\"entries\":[{\"id\":1,\"text\":\"Synthetic\",\"createdAt\":\"2026-09-17T10:00:00Z\",\"source\":\"phone:\(entry.id.uuidString)\"}]}")
        }
        let account = AccountSession(store: MemoryCredentials(owner), defaults: defaults)
        await account.refresh()
        XCTAssertEqual(posts, 0)
        let remaining = try! JSONDecoder().decode([AccountSession.Upload].self, from: defaults.data(forKey: key)!)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(account.history.count, 1)
    }

    func testLegacyLocalHistoryDecodesWithoutAccountField() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"text\":\"Local\",\"date\":100,\"source\":\"containerApp\"}"
        let entry = try JSONDecoder().decode(DictationEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.accountKey)
        XCTAssertEqual(entry.text, "Local")
    }
}
