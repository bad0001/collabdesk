import XCTest
import Security
import AppIntents
@testable import CollabDesk

final class SMSAutomationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var credential: CodeAutomationCredential {
        CodeAutomationCredential(binding: CodeAutomationBinding(endpoint: "https://fixture.example", workspaceID: "fixture-workspace", memberID: "fixture-user", installationID: "fixture-install"), credential: String(repeating: "x", count: 43), enabledAt: "2026-10-10T00:00:00Z")
    }
    func testAutomaticParsingBrandPurposeExpiryAndReceivedTimestamp() throws {
        let stamp = now.addingTimeInterval(-30)
        let value = try XCTUnwrap(SMSAutomaticParser.payload(message: "【招聘网站】登录验证码 012345，2分钟内有效，请勿泄露。", receivedTime: stamp, now: now))
        XCTAssertEqual(value.codes, ["012345"])
        XCTAssertEqual(value.source, "招聘网站"); XCTAssertEqual(value.purpose, "login")
        XCTAssertEqual(value.timeSource, "received"); XCTAssertEqual(value.receivedAt, ISO8601DateFormatter().string(from: stamp))
        XCTAssertEqual(value.expiresIn, 120)
    }
    func testCapturedTimeAndUnknownFieldsStayExplicit() throws {
        let value = try XCTUnwrap(SMSAutomaticParser.payload(message: "您的验证码是123456，请保密。", receivedTime: nil, now: now))
        XCTAssertEqual(value.source, ""); XCTAssertEqual(value.purpose, "unknown")
        XCTAssertEqual(value.timeSource, "captured"); XCTAssertEqual(value.receivedAt, ISO8601DateFormatter().string(from: now))
        XCTAssertEqual(value.expiresIn, 300)
    }
    func testOnlyExplicitCandidatesNotOrdersAmountsPhonesOrDates() throws {
        for text in ["订单123456，金额1000元", "验证码订单编号123456", "验证码交易金额1234元", "验证码金额1234.56", "验证码发送日期2026-10-10", "验证码发送至13812345678", "电话13812345678"] {
            XCTAssertNil(try SMSAutomaticParser.payload(message: text, receivedTime: nil, now: now), text)
        }
    }
    func testMultipleCandidatesAreOneBatchAndNeverTruncated() throws {
        let value = try XCTUnwrap(SMSAutomaticParser.payload(message: "【网站】验证码123456\nOTP987654\n验证码123456", receivedTime: nil, now: now))
        XCTAssertEqual(value.codes, ["123456", "987654"])
        let tooMany = (1...7).map { "验证码 \(100_000 + $0)" }.joined(separator: "\n")
        XCTAssertThrowsError(try SMSAutomaticParser.payload(message: tooMany, receivedTime: nil, now: now)) { XCTAssertEqual($0 as? SMSAutomationError, .tooManyCandidates) }
    }
    func testAmbiguousPurposeAndUnsafeBrandRemainUnknown() throws {
        XCTAssertEqual(SMSAutomaticParser.purpose(in: "登录或注册验证码"), "unknown")
        XCTAssertEqual(SMSAutomaticParser.purpose(in: "reset your password with the code"), "reset")
        for text in ["【123456】验证码123456", "【https://example.com】验证码123456", "【验证码123456】验证码123456", "普通内容【网站】验证码123456"] { XCTAssertEqual(SMSAutomaticParser.brand(in: text), "") }
    }
    func testExpiryUsesExplicitMinimumAndCapsAtFifteenMinutes() {
        XCTAssertEqual(SMSAutomaticParser.expirySeconds(in: "有效期为5分钟，60秒后失效"), 60)
        XCTAssertEqual(SMSAutomaticParser.expirySeconds(in: "valid for 20 minutes"), 900)
        XCTAssertEqual(SMSAutomaticParser.expirySeconds(in: "有效1小时"), 900)
        XCTAssertEqual(SMSAutomaticParser.expirySeconds(in: "请5分钟后再次申请"), 300)
        XCTAssertEqual(SMSAutomaticParser.expirySeconds(in: "有效期：2分钟"), 120)
        XCTAssertEqual(SMSAutomaticParser.expirySeconds(in: "valid for 30 secs"), 30)
    }
    func testStaleOrFutureSMSIsNeverRebasedToNow() {
        XCTAssertThrowsError(try SMSAutomaticParser.payload(message: "验证码123456有效1分钟", receivedTime: now.addingTimeInterval(-61), now: now)) { XCTAssertEqual($0 as? SMSAutomationError, .expired) }
        XCTAssertThrowsError(try SMSAutomaticParser.payload(message: "验证码123456", receivedTime: now.addingTimeInterval(120), now: now))
    }
    func testBindingRequiresSameOriginAccountWorkspaceAndAdmin() throws {
        let value = credential.binding
        XCTAssertTrue(value.matches(endpoint: "https://FIXTURE.example/", workspaceID: "fixture-workspace", memberID: "fixture-user", role: "admin", demo: false))
        XCTAssertFalse(value.matches(endpoint: "https://other.example", workspaceID: value.workspaceID, memberID: value.memberID, role: "admin", demo: false))
        XCTAssertFalse(value.matches(endpoint: value.endpoint, workspaceID: "other", memberID: value.memberID, role: "admin", demo: false))
        XCTAssertFalse(value.matches(endpoint: value.endpoint, workspaceID: value.workspaceID, memberID: "other", role: "admin", demo: false))
        XCTAssertFalse(value.matches(endpoint: value.endpoint, workspaceID: value.workspaceID, memberID: value.memberID, role: "worker", demo: false))
        XCTAssertFalse(value.matches(endpoint: value.endpoint, workspaceID: value.workspaceID, memberID: value.memberID, role: "admin", demo: true))
        for bad in ["http://fixture.example", "https://user:password@fixture.example", "https://fixture.example/v1", "https://fixture.example?token=x", "https://fixture.example#x"] { XCTAssertThrowsError(try CodeAutomationBinding.origin(bad)) }
    }
    func testIngestRequestHasNarrowCredentialOnlyAndNoSMSBody() throws {
        let payload = try XCTUnwrap(SMSAutomaticParser.payload(message: "【网站】登录验证码012345，私人正文不应上传", receivedTime: nil, now: now))
        let value = try SMSAutomaticTransport.request(payload: payload, credential: credential)
        XCTAssertEqual(value.url?.absoluteString, "https://fixture.example/v1/codes/ingest")
        XCTAssertEqual(value.httpMethod, "POST"); XCTAssertEqual(value.timeoutInterval, 15)
        XCTAssertEqual(value.value(forHTTPHeaderField: "Authorization"), "CodeIngest " + credential.credential)
        XCTAssertEqual(value.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = try XCTUnwrap(value.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["codes", "source", "purpose", "receivedAt", "timeSource", "expiresIn"]))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("私人正文")); XCTAssertFalse(text.contains(credential.credential))
        XCTAssertNil(value.url?.query)
    }
    func testEphemeralNoCacheCookiesOrCredentialStorage() {
        let value = SMSAutomaticTransport.configuration()
        XCTAssertNil(value.urlCache); XCTAssertNil(value.httpCookieStorage); XCTAssertNil(value.urlCredentialStorage)
        XCTAssertEqual(value.timeoutIntervalForRequest, 15); XCTAssertEqual(value.timeoutIntervalForResource, 15)
        XCTAssertFalse(value.waitsForConnectivity); XCTAssertFalse(value.httpShouldSetCookies)
        XCTAssertEqual(value.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }
    func testKeychainSeparateScopeAccessibilityAndNoSync() {
        XCTAssertNotEqual(CodeAutomationKeychain.service, CredentialStore.service)
        XCTAssertEqual(CodeAutomationKeychain.accessibility, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(CodeAutomationKeychain.query(account: "active")[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertTrue(credential.valid)
        XCTAssertFalse(CodeAutomationCredential(binding: credential.binding, credential: "full-admin-bearer-or-malformed", enabledAt: "").valid)
    }
    func testActualKeychainGrantReconcileAndDeletionOnFixtureSimulator() throws {
        try CodeAutomationKeychain.stop()
        defer { try? CodeAutomationKeychain.stop() }
        try CodeAutomationKeychain.save(credential)
        XCTAssertEqual(try CodeAutomationKeychain.read(), credential)
        var query = CodeAutomationKeychain.query(account: "active")
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try CodeAutomationKeychain.reconcile(endpoint: credential.binding.endpoint, workspaceID: credential.binding.workspaceID, memberID: credential.binding.memberID, role: "admin", demo: false)
        XCTAssertEqual(try CodeAutomationKeychain.read(), credential)
        try CodeAutomationKeychain.reconcile(endpoint: "https://other.example", workspaceID: credential.binding.workspaceID, memberID: credential.binding.memberID, role: "admin", demo: false)
        XCTAssertNil(try CodeAutomationKeychain.read())
    }
    @MainActor func testDemoSwitchStopsActiveCapabilityAndDoesNotCreateQueue() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? CodeAutomationKeychain.stop(); try? FileManager.default.removeItem(at: folder) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = DeskStore(directory: folder, defaults: defaults, forceDemo: true)
        try CodeAutomationKeychain.save(credential)
        store.useDemo()
        XCTAssertNil(try CodeAutomationKeychain.read()); XCTAssertTrue(store.isDemo)
        XCTAssertNil(store.pendingWrite)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains(credential.credential) == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pending.json").path))
    }
    func testBackgroundIntentDoesNotOpenAppAndManualRemains() {
        XCTAssertFalse(AutomaticallyIngestSMSCodeIntent.openAppWhenRun)
        XCTAssertTrue(ExtractSMSCodeIntent.openAppWhenRun)
        XCTAssertEqual(AutomaticallyIngestSMSCodeIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(SMSCodeParser.candidates(in: "验证码123456"), ["123456"])
    }
    func testMetadataAcceptsNewAutomaticFieldsAndLegacyManualShape() throws {
        let old = #"{"id":"fixture-code","service":"网站","accountLabel":"账号","purpose":"login","state":"available","version":1,"receivedAt":"","expiresAt":"","createdAt":""}"#
        let value = try JSONDecoder().decode(VerificationCodeMetadata.self, from: Data(old.utf8))
        XCTAssertNil(value.importMethod)
        let automatic = old.dropLast() + #", "importMethod":"automatic","sourceKnown":true,"purposeKnown":false,"timeSource":"captured"}"#
        let fresh = try JSONDecoder().decode(VerificationCodeMetadata.self, from: Data(automatic.utf8))
        XCTAssertEqual(fresh.importMethod, "automatic"); XCTAssertEqual(fresh.timeSource, "captured")
    }
    func testNetworkSuccessReturnsCountNotBodyOrCode() async throws {
        let value = try XCTUnwrap(SMSAutomaticParser.payload(message: "验证码123456", receivedTime: nil, now: now))
        SMSTestURLProtocol.handler = { request in (201, Data(#"{"imported":1,"codes":[]}"#.utf8)) }
        let session = fixtureSession(); defer { session.invalidateAndCancel(); SMSTestURLProtocol.handler = nil }
        let count = try await SMSAutomaticTransport.send(payload: value, credential: credential, session: session)
        XCTAssertEqual(count, 1)
    }
    func testNoCandidatesNeverReadsCredentialOrSendsNetwork() async throws {
        let importer = SMSAutomaticImporter(readCredential: { throw SMSAutomationError.invalidCredential }, send: { _, _ in throw SMSAutomationError.network })
        let value = try await importer.ingest(message: "订单123456", receivedTime: nil, now: now)
        XCTAssertNil(value)
    }
    func testDisabledImporterNeverUploads() async throws {
        let importer = SMSAutomaticImporter(readCredential: { nil }, send: { _, _ in XCTFail("Network should not run"); return 1 })
        do { _ = try await importer.ingest(message: "验证码123456", receivedTime: nil, now: now); XCTFail("Should require one-time opt-in") }
        catch { XCTAssertEqual(error as? SMSAutomationError, .disabled) }
    }
    func testImporterRevokesLocalCapabilityOnUnauthorizedResponse() async throws {
        let value = credential, flag = SMSFixtureFlag()
        let importer = SMSAutomaticImporter(readCredential: { value }, stop: { flag.mark() }, send: { _, _ in throw SMSAutomationError.response(401) })
        do { _ = try await importer.ingest(message: "验证码123456", receivedTime: nil, now: now); XCTFail("Should reject") }
        catch { XCTAssertEqual(error as? SMSAutomationError, .response(401)) }
        XCTAssertTrue(flag.marked)
    }
    func testHTTPFailureHasSingleRequestAndSanitizedError() async throws {
        let value = try XCTUnwrap(SMSAutomaticParser.payload(message: "验证码123456", receivedTime: nil, now: now))
        SMSTestURLProtocol.requests = 0
        SMSTestURLProtocol.handler = { request in (403, Data(#"{"error":"SECRET_OR_SMS_MUST_NOT_APPEAR"}"#.utf8)) }
        let session = fixtureSession(); defer { session.invalidateAndCancel(); SMSTestURLProtocol.handler = nil }
        do { _ = try await SMSAutomaticTransport.send(payload: value, credential: credential, session: session); XCTFail("Should reject") }
        catch { XCTAssertEqual(error as? SMSAutomationError, .response(403)); XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
        XCTAssertEqual(SMSTestURLProtocol.requests, 1)
    }
    func testRedirectResponseNeverAcceptedAsIngestSuccess() async throws {
        let value = try XCTUnwrap(SMSAutomaticParser.payload(message: "验证码123456", receivedTime: nil, now: now))
        SMSTestURLProtocol.requests = 0
        SMSTestURLProtocol.handler = { request in (302, Data(#"{"imported":1}"#.utf8)) }
        let session = fixtureSession(); defer { session.invalidateAndCancel(); SMSTestURLProtocol.handler = nil }
        do { _ = try await SMSAutomaticTransport.send(payload: value, credential: credential, session: session); XCTFail("Should reject") }
        catch { XCTAssertEqual(error as? SMSAutomationError, .response(302)) }
        XCTAssertEqual(SMSTestURLProtocol.requests, 1)
    }
    private func fixtureSession() -> URLSession {
        let value = SMSAutomaticTransport.configuration(); value.protocolClasses = [SMSTestURLProtocol.self]
        return URLSession(configuration: value, delegate: NoRedirect(), delegateQueue: nil)
    }
}

private final class SMSFixtureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); defer { lock.unlock() }; value = true }
    var marked: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class SMSTestURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
