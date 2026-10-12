import Foundation

struct InboxAPIError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 404: return "后台尚未发布这项功能，现有消息仍可正常使用。"
        case 401, 403: return "请检查当前账号权限或重新连接。"
        case 409: return "这条记录已变化，请刷新后重新选择。"
        case 410: return "验证码已过期或已使用，请重新申请。"
        default: return "本次提交未确认，请刷新后核实；敏感内容未保存到本机重试队列。"
        }
    }
}

extension DeskStore {
    func replyUserRequest(_ item: UserRequest, body: String, resolve: Bool = false) async -> Bool {
        guard !isDemo, snapshot.userRequests != nil else { error = "后台尚未发布求助中心，请使用现有会话回复。"; return false }
        guard snapshot.me.role == "admin", item.kind != "code" else { error = "验证码请在验证码库按申请分发，回复不会批准授权。"; return false }
        return await write(path: "/v1/user-requests/\(item.id)/reply", payload: ["version": item.version, "body": body, "resolve": resolve])
    }
    func resolveUserRequest(_ item: UserRequest) async -> Bool {
        guard !isDemo, snapshot.userRequests != nil else { error = "后台尚未发布求助中心。"; return false }
        return await write(path: "/v1/user-requests/\(item.id)/resolve", payload: ["version": item.version])
    }
}
