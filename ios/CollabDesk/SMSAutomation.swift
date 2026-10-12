import Foundation
import Security

/// Payload contains only explicitly extracted candidates and minimal metadata.
/// Full messages and sender addresses never leave the Shortcuts action's RAM.
struct SMSAutomaticPayload: Codable, Equatable, Sendable {
    let codes: [String]
    let source: String
    let purpose: String
    let receivedAt: String
    let timeSource: String
    let expiresIn: Int
}

enum SMSAutomationError: Error, LocalizedError, Equatable {
    case disabled, bindingChanged, badConnection, invalidCredential, keychain
    case tooManyCandidates, expired, network, response(Int)
    var errorDescription: String? {
        switch self {
        case .disabled: return "请先在协作台的验证码库启用短信自动入库。"
        case .bindingChanged: return "平台或账号已变化，请在协作台重新启用短信自动入库。"
        case .badConnection: return "自动入库需要已连接的 HTTPS 协作台。"
        case .invalidCredential, .keychain: return "自动入库凭据尚未就绪，请打开协作台重新启用；设备重启后需先解锁一次。"
        case .tooManyCandidates: return "验证码候选过多，本次未上传；可在协作台手动导入。"
        case .expired: return "这条信息已超过验证码有效期，本次未上传。"
        case .network: return "本次自动入库未确认，未保存短信或重试队列；可在协作台查看结果。"
        case .response(let status):
            return status == 401 || status == 403 ? "自动入库权限已停用，请在协作台重新启用。" : "本次自动入库未确认，请在协作台查看结果。"
        }
    }
}

enum SMSAutomaticParser {
    static func payload(message: String, receivedTime: Date?, now: Date = Date()) throws -> SMSAutomaticPayload? {
        // Existing manual extraction remains unchanged. Automatic ingestion
        // applies a stricter label-to-number bridge to reject order/money data.
        let label = #"(?:验证码|校验码|验证代码|动态码|verification(?:\s+code)?|one[-\s]time(?:\s+(?:code|password))?|otp|passcode|security\s+code|authentication\s+code)"#
        let number = #"(?<![0-9])([0-9]{4,8})(?![0-9.]|[-/][0-9]|,[0-9]{3}|\s*(?:元|块|美元|USD|CNY|RMB))"#
        let patterns = [label + #"([^0-9\r\n$¥￥]{0,32})"# + number,
                        number + #"([^0-9\r\n$¥￥]{0,16})(?:是|为|is|as)?\s*"# + label]
        var codes: [String] = []
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
                let bridgeIndex = index == 0 ? 1 : 2, codeIndex = index == 0 ? 2 : 1
                guard let bridge = Range(match.range(at: bridgeIndex), in: message),
                      let candidate = Range(match.range(at: codeIndex), in: message) else { continue }
                let context = String(message[bridge])
                guard context.range(of: #"订单|金额|费用|价格|日期|电话|手机号|手机号码|order|amount|price|phone|date"#, options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                let code = String(message[candidate])
                if !codes.contains(code) { codes.append(code) }
            }
        }
        guard !codes.isEmpty else { return nil }
        guard codes.count <= 6 else { throw SMSAutomationError.tooManyCandidates }
        let stamp = receivedTime ?? now
        let expiry = expirySeconds(in: message)
        guard stamp <= now.addingTimeInterval(60), stamp.addingTimeInterval(TimeInterval(expiry)) > now else { throw SMSAutomationError.expired }
        return SMSAutomaticPayload(codes: codes, source: brand(in: message), purpose: purpose(in: message),
                                   receivedAt: ISO8601DateFormatter().string(from: stamp),
                                   timeSource: receivedTime == nil ? "captured" : "received", expiresIn: expiry)
    }

    static func brand(in message: String) -> String {
        // Only an explicit leading brand signature is extracted; not an inferred
        // account, sender phone number, URL or a general piece of SMS prose.
        let patterns = [#"^\s*【([^】]{1,48})】"#, #"^\s*\[([^\]]{1,48})\]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message) else { continue }
            let value = String(message[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 48,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  value.range(of: #"^[A-Za-z0-9\u4e00-\u9fff &._·-]+$"#, options: .regularExpression) != nil,
                  value.range(of: #"https?://|www\.|[0-9]{4,}|验证码|校验码|otp|verification"#, options: [.regularExpression, .caseInsensitive]) == nil else { return "" }
            return value
        }
        return ""
    }

    static func purpose(in message: String) -> String {
        let groups: [(String, String)] = [("reset", #"重置|找回密码|reset\s+(?:your\s+)?password|password\s+reset"#),
                                          ("register", #"注册|register|registration|sign\s*up"#),
                                          ("login", #"登录|登陆|log\s*in|sign\s*in"#)]
        let found = groups.compactMap { value, pattern in
            message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? nil : value
        }
        return found.count == 1 ? found[0] : "unknown"
    }

    static func expirySeconds(in message: String) -> Int {
        let units = #"(秒|分钟|分|小时|seconds?|secs?|minutes?|mins?|hours?|hrs?)"#
        let patterns = [#"(?:有效(?:期|时间)?(?:为|是)?\s*[:：]?\s*|valid\s+(?:for\s+)?)([0-9]{1,5})\s*"# + units,
                        #"([0-9]{1,5})\s*"# + units + #"\s*(?:内有效|有效|后失效|后过期)"#]
        var values: [Int] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
                guard let number = Range(match.range(at: 1), in: message), let unit = Range(match.range(at: 2), in: message),
                      let value = Int(message[number]) else { continue }
                let text = message[unit].lowercased()
                let multiplier = text == "小时" || text.hasPrefix("hour") || text.hasPrefix("hr") ? 3600 : (text == "秒" || text.hasPrefix("sec") ? 1 : 60)
                values.append(max(1, min(900, value * multiplier)))
            }
        }
        return values.min() ?? 300
    }
}

struct CodeAutomationBinding: Codable, Equatable, Sendable {
    let endpoint: String
    let workspaceID: String
    let memberID: String
    let installationID: String
    static func origin(_ text: String) throws -> String {
        guard var value = URLComponents(string: text), value.scheme?.lowercased() == "https",
              let host = value.host, !host.isEmpty, value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil, value.path.isEmpty || value.path == "/" else { throw SMSAutomationError.badConnection }
        value.scheme = "https"; value.host = host.lowercased(); value.path = ""
        guard let result = value.url?.absoluteString else { throw SMSAutomationError.badConnection }
        return result
    }
    func matches(endpoint: String, workspaceID: String?, memberID: String, role: String, demo: Bool) -> Bool {
        !demo && role == "admin" && (try? Self.origin(endpoint)) == self.endpoint &&
        workspaceID == self.workspaceID && memberID == self.memberID && !installationID.isEmpty
    }
}
struct CodeAutomationCredential: Codable, Equatable, Sendable {
    let binding: CodeAutomationBinding
    let credential: String
    let enabledAt: String
    var valid: Bool {
        credential.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil &&
        !binding.workspaceID.isEmpty && !binding.memberID.isEmpty && !binding.installationID.isEmpty &&
        (try? CodeAutomationBinding.origin(binding.endpoint)) == binding.endpoint
    }
}

enum CodeAutomationKeychain {
    static let service = "org.example.collabdesk.code-ingest"
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func readData(account: String) throws -> Data? {
        var value = query(account: account)
        value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SMSAutomationError.keychain }
        return data
    }
    static func saveData(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility]
        let status = SecItemUpdate(query(account: account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account: account).merging(values) { _, next in next } as CFDictionary, nil) == errSecSuccess else { throw SMSAutomationError.keychain }
        } else if status != errSecSuccess { throw SMSAutomationError.keychain }
    }
    static func installationID() throws -> String {
        if let data = try readData(account: "installation"), let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
        let value = UUID().uuidString
        try saveData(Data(value.utf8), account: "installation")
        return value
    }
    static func read() throws -> CodeAutomationCredential? {
        guard let data = try readData(account: "active") else { return nil }
        guard let value = try? JSONDecoder().decode(CodeAutomationCredential.self, from: data), value.valid else { throw SMSAutomationError.invalidCredential }
        return value
    }
    static func save(_ value: CodeAutomationCredential) throws {
        guard value.valid else { throw SMSAutomationError.invalidCredential }
        try saveData(JSONEncoder().encode(value), account: "active")
    }
    static func stop() throws {
        let status = SecItemDelete(query(account: "active") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SMSAutomationError.keychain }
    }
    static func reconcile(endpoint: String, workspaceID: String?, memberID: String, role: String, demo: Bool) throws {
        if let value = try read(), !value.binding.matches(endpoint: endpoint, workspaceID: workspaceID, memberID: memberID, role: role, demo: demo) { try stop() }
    }
}

struct CodeIngestResult: Decodable { let imported: Int }

struct SMSAutomaticTransport {
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return config
    }
    static func request(payload: SMSAutomaticPayload, credential: CodeAutomationCredential) throws -> URLRequest {
        guard credential.valid, let url = URL(string: credential.binding.endpoint)?.appendingPathComponent("v1/codes/ingest") else { throw SMSAutomationError.invalidCredential }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("CodeIngest \(credential.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
    static func send(payload: SMSAutomaticPayload, credential: CodeAutomationCredential, session suppliedSession: URLSession? = nil) async throws -> Int {
        let request = try request(payload: payload, credential: credential)
        let session = suppliedSession ?? URLSession(configuration: configuration(), delegate: NoRedirect(), delegateQueue: nil)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SMSAutomationError.network }
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw SMSAutomationError.network }
        guard (200..<300).contains(response.statusCode) else { throw SMSAutomationError.response(response.statusCode) }
        guard let value = try? JSONDecoder().decode(CodeIngestResult.self, from: data), (0...payload.codes.count).contains(value.imported) else { throw SMSAutomationError.network }
        return value.imported
    }
}

/// Runs in the intent's background context, independently of the app's stores.
/// There is no pending-write queue, body logging, SMS database or retry task.
actor SMSAutomaticImporter {
    static let shared = SMSAutomaticImporter()
    private let readCredential: @Sendable () throws -> CodeAutomationCredential?
    private let stop: @Sendable () throws -> Void
    private let send: @Sendable (SMSAutomaticPayload, CodeAutomationCredential) async throws -> Int
    init(readCredential: @escaping @Sendable () throws -> CodeAutomationCredential? = { try CodeAutomationKeychain.read() },
         stop: @escaping @Sendable () throws -> Void = { try CodeAutomationKeychain.stop() },
         send: @escaping @Sendable (SMSAutomaticPayload, CodeAutomationCredential) async throws -> Int = { try await SMSAutomaticTransport.send(payload: $0, credential: $1) }) {
        self.readCredential = readCredential; self.stop = stop; self.send = send
    }
    func ingest(message: String, receivedTime: Date?, now: Date = Date()) async throws -> Int? {
        guard let payload = try SMSAutomaticParser.payload(message: message, receivedTime: receivedTime, now: now) else { return nil }
        guard let value = try readCredential() else { throw SMSAutomationError.disabled }
        guard value.valid, try readCredential() == value else { throw SMSAutomationError.bindingChanged }
        do { return try await send(payload, value) }
        catch SMSAutomationError.response(let status) where status == 401 || status == 403 {
            try stop()
            throw SMSAutomationError.response(status)
        }
    }
}
