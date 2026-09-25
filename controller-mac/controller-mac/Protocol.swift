import Foundation

// 消息协议（与 server/src/protocol.ts 对齐）
// 路由规则：controller 发出的消息带 targetId（目标 client），由 server 转发；
// client 发出的响应消息原样广播给所有 controller，各自按 reqId 过滤。

nonisolated struct ClientInfo: Identifiable, Equatable {
    let clientId: String
    let connectedAt: Double
    var id: String { clientId }
}

// 输出条目类型：stdout/stderr 为命令输出，system 为本地系统消息，command 为输入回显
nonisolated enum OutputKind: Equatable {
    case stdout
    case stderr
    case system
    case command
}

nonisolated struct OutputLine: Identifiable {
    let id = UUID()
    let kind: OutputKind
    var text: String
}

// 收到的消息（已按 type 分发）
nonisolated enum IncomingMessage {
    case registered(ok: Bool, error: String?)
    case clients([ClientInfo])
    case execOutput(reqId: String, stream: String, data: String)
    case execExit(reqId: String, code: Int?)
    case fileContent(content: String?, error: String?)
    case done(ok: Bool, error: String?)
    case error(message: String)

    static func parse(_ text: String) -> IncomingMessage? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "registered":
            return .registered(
                ok: obj["ok"] as? Bool ?? false,
                error: obj["error"] as? String
            )
        case "clients":
            let list = (obj["clients"] as? [[String: Any]] ?? []).map {
                ClientInfo(
                    clientId: $0["clientId"] as? String ?? "",
                    connectedAt: $0["connectedAt"] as? Double ?? 0
                )
            }
            return .clients(list)
        case "exec-output":
            return .execOutput(
                reqId: obj["reqId"] as? String ?? "",
                stream: obj["stream"] as? String ?? "stdout",
                data: obj["data"] as? String ?? ""
            )
        case "exec-exit":
            let code: Int?
            if let c = obj["code"] as? Int { code = c } else { code = nil }
            return .execExit(reqId: obj["reqId"] as? String ?? "", code: code)
        case "file-content":
            return .fileContent(
                content: obj["content"] as? String,
                error: obj["error"] as? String
            )
        case "done":
            return .done(
                ok: obj["ok"] as? Bool ?? false,
                error: obj["error"] as? String
            )
        case "error":
            return .error(message: obj["message"] as? String ?? "未知错误")
        default:
            return nil
        }
    }
}

// 发出的消息构造（JSON 字符串）
nonisolated enum OutgoingMessage {
    static func register(clientId: String, token: String) -> String {
        json(["type": "register", "role": "controller", "clientId": clientId, "token": token])
    }

    static func listClients() -> String {
        json(["type": "list-clients"])
    }

    static func exec(reqId: String, targetId: String, command: String) -> String {
        json(["type": "exec", "reqId": reqId, "targetId": targetId, "command": command])
    }

    static func fileRead(reqId: String, targetId: String, path: String) -> String {
        json(["type": "file-read", "reqId": reqId, "targetId": targetId, "path": path])
    }

    static func fileWrite(reqId: String, targetId: String, path: String, content: String) -> String {
        json(["type": "file-write", "reqId": reqId, "targetId": targetId, "path": path, "content": content])
    }

    private static func json(_ dict: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// 剥除 ANSI 转义序列（颜色码等），避免终端输出在 Text 里显示乱码
nonisolated enum Ansiless {
    // 注意：\u{XX} 在这里是 Swift 插值出的真实控制字符；ICU 正则自身不支持 \u{XX} 花括号转义
    private static let patterns: [NSRegularExpression] = [
        "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",                    // CSI
        "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", // OSC
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func strip(_ text: String) -> String {
        var result = text
        for regex in patterns {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ""
            )
        }
        return result
    }
}
