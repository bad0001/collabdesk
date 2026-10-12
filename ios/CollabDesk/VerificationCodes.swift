import Foundation

/// Only explicitly labelled codes are candidates. Extraction does not upload,
/// save the SMS, guess its account, or authorize an AI to use the result.
enum SMSCodeParser {
    static func candidates(in text: String) -> [String] {
        let label = #"(?:验证码|校验码|验证代码|动态码|verification(?:\s+code)?|one[-\s]time(?:\s+(?:code|password))?|otp|passcode|security\s+code|authentication\s+code)"#
        let number = #"(?<![0-9])([0-9]{4,8})(?![0-9.]|[-/][0-9]|,[0-9]{3}|\s*(?:元|块|美元|USD|CNY|RMB))"#
        let patterns = [label + #"[^0-9\r\n$¥￥]{0,32}"# + number,
                        number + #"[^0-9\r\n$¥￥]{0,16}(?:是|为|is|as)?\s*"# + label]
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let code = String(text[range])
                if !found.contains(code) { found.append(code) }
            }
        }
        return found
    }
}

struct VerificationCodeMetadata: Codable, Identifiable, Equatable {
    let id: String
    var service: String
    var accountLabel: String
    var purpose: String
    var state: String
    var version: Int
    var receivedAt: String
    var expiresAt: String
    var createdAt: String
    var assignedRequestId: Int?
    var assignedMemberId: String?
    var taskId: String?
    var importMethod: String? = nil
    var sourceKnown: Bool? = nil
    var purposeKnown: Bool? = nil
    var timeSource: String? = nil
    var purposeLabel: String { ["login":"登录", "register":"注册", "reset":"重置密码", "verification":"验证", "unknown":"用途未知"][purpose] ?? purpose }
    var usable: Bool { usable(at: Date()) }
    func usable(at time: Date) -> Bool { ["available", "assigned"].contains(state) && (DeskDate.date(expiresAt).map { $0 > time } ?? false) }
    var stateLabel: String { ["available":"待分发", "assigned":"已定向分发", "consumed":"已使用", "expired":"已过期", "replaced":"已替换", "lost":"需重新导入"][state] ?? state }
}
struct CodeRequestMetadata: Codable, Identifiable, Equatable {
    let id: Int
    var taskId: String
    var requesterId: String
    var requesterName: String
    var service: String
    var accountLabel: String
    var purpose: String
    var state: String
    var version: Int
    var codeId: String?
    var createdAt: String
    var updatedAt: String
    func matches(_ code: VerificationCodeMetadata) -> Bool {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return clean(service) == clean(code.service) && clean(accountLabel) == clean(code.accountLabel) && clean(purpose) == clean(code.purpose)
    }
}
struct CodeVaultResponse: Decodable { var codes: [VerificationCodeMetadata]; var codeRequests: [CodeRequestMetadata] }
struct CodeImportResponse: Decodable { var code: VerificationCodeMetadata }

extension DeskStore {
    func loadCodeVault() async throws -> CodeVaultResponse {
        try JSONDecoder().decode(CodeVaultResponse.self, from: await privateInboxRequest(path: "/v1/codes"))
    }
    func importVerificationCode(code: String, service: String, account: String, purpose: String, expiresIn: Int, receivedAt: Date, key: String) async throws -> VerificationCodeMetadata {
        guard snapshot.me.role == "admin", code.range(of: #"^[0-9]{4,8}$"#, options: .regularExpression) != nil,
              (60...900).contains(expiresIn) else { throw DeskError(message: "请检查验证码、有效期和用户身份。") }
        let payload: [String: Any] = ["code":code, "service":service, "accountLabel":account, "purpose":purpose, "expiresIn":expiresIn, "receivedAt":DeskDate.string(receivedAt)]
        return try JSONDecoder().decode(CodeImportResponse.self, from: await privateInboxRequest(path: "/v1/codes", method: "POST", payload: payload, idempotencyKey: key)).code
    }
    func assignVerificationCode(_ code: VerificationCodeMetadata, to request: CodeRequestMetadata) async throws {
        guard ["admin", "leader"].contains(snapshot.me.role), request.state == "waiting", request.matches(code),
              code.id.range(of: #"^[A-Za-z0-9_-]{8,128}$"#, options: .regularExpression) != nil else { throw DeskError(message: "来源、账号和用途需与申请一致，请刷新后选择。") }
        _ = try await privateInboxRequest(path: "/v1/codes/\(code.id)/assign", method: "POST", payload: ["requestId":request.id, "version":code.version])
    }
}
