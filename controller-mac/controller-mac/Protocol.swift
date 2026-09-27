import Foundation

// 消息协议（与 server/src/protocol.ts 对齐）
// 路由规则：controller 发出的消息带 targetId（目标 client），由 server 转发；
// client 发出的响应消息原样广播给所有 controller，各自按 reqId 过滤；
// 保留目标 @server：exec 与文件类消息（file-list/read/write/create/delete）由 server 就地处理
// （在服务器本机执行命令 / 浏览其文件，路径即 server 上的路径），响应直接回给发起的 controller。

nonisolated struct ClientInfo: Identifiable, Equatable {
    let clientId: String
    let connectedAt: Double
    let version: String? // client 注册时上报的自身版本，旧版 client 不带
    var id: String { clientId }
}

// 白名单客户端（服务端 clients.json 的一条记录），online 为下发时刻是否在线
nonisolated struct WhitelistClient: Identifiable, Equatable {
    let clientId: String
    let token: String
    let online: Bool
    var id: String { clientId }
}

// 中间列的统一客户端行：白名单条目 + 实时在线状态（在线不再是筛选条件，只是状态）。
// token 为 nil 表示该行仅来自在线列表（旧版 server 不下发白名单时的回退，不可编辑）；
// version 仅在线时已知（来自该 client 注册时的上报）
nonisolated struct ClientRow: Identifiable, Equatable {
    let clientId: String
    let token: String?
    var online: Bool
    var version: String?
    var id: String { clientId }
}

// 远程目录条目（client 端 stat 的结果；other 为失效符号链接、设备文件等）
nonisolated enum FileEntryKind: String, Equatable {
    case dir
    case file
    case other
}

nonisolated struct FileEntryInfo: Identifiable, Equatable {
    let name: String
    let kind: FileEntryKind
    let size: Double // 字节，仅 file 有意义
    let mtime: Double // 修改时间（毫秒），0 表示取不到
    var id: String { name }
}

// 文件操作请求的响应（fileCallbacks 回调参数）
nonisolated enum FileReply {
    case listing(path: String, entries: [FileEntryInfo])
    case content(String)
    case ack(ok: Bool, error: String?) // 写入回执
    case failure(String)
}

// 文件操作的对外结果（failed 直接携带用户可读的错误文本）
nonisolated enum FileOutcome<Value> {
    case ok(Value)
    case failed(String)
}

// Claude Code 会话快照；真实持久化文件仅位于云电脑 client 的 ~/.link-projects/claude-sessions.json。
nonisolated enum AgentSessionState: String, Equatable {
    case running
    case completed
    case failed
}

nonisolated struct AgentMessageInfo: Identifiable, Equatable {
    let role: String
    let content: String
    let createdAt: Double
    var id: String { "\(role)-\(createdAt)-\(content.hashValue)" }
}

nonisolated struct AgentSessionInfo: Identifiable, Equatable {
    let sessionId: String
    let title: String
    let cwd: String?
    let state: AgentSessionState
    let createdAt: Double
    let updatedAt: Double
    let error: String?
    let messages: [AgentMessageInfo]
    var id: String { sessionId }
}

// 输出条目类型：stdout/stderr 为命令输出，system 为本地系统消息，command 为输入回显，separator 为每次交互结束的分隔线
nonisolated enum OutputKind: Equatable {
    case stdout
    case stderr
    case system
    case command
    case separator
}

nonisolated struct OutputLine: Identifiable {
    let id = UUID()
    let kind: OutputKind
    var text: String
}

// 收到的消息（已按 type 分发）；client 响应均带 targetId（= 来源 client 的 id），用于按客户端分流输出
// done/error 带 reqId：白名单管理类请求据此路由到对应回调，而非显示到终端
nonisolated enum IncomingMessage {
    case registered(ok: Bool, error: String?, serverVersion: String?)
    case clients([ClientInfo])
    case whitelist([WhitelistClient], reqId: String?)
    case execOutput(reqId: String, stream: String, data: String, targetId: String)
    case execExit(reqId: String, code: Int?, targetId: String)
    case fileContent(reqId: String, content: String?, error: String?, targetId: String)
    case fileListing(reqId: String, path: String, entries: [FileEntryInfo]?, error: String?, targetId: String)
    case done(reqId: String, ok: Bool, error: String?, targetId: String)
    case error(reqId: String?, message: String)
    case agentSessions(reqId: String, targetId: String, sessions: [AgentSessionInfo])

    static func parse(_ text: String) -> IncomingMessage? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "registered":
            return .registered(
                ok: obj["ok"] as? Bool ?? false,
                error: obj["error"] as? String,
                serverVersion: obj["serverVersion"] as? String
            )
        case "clients":
            let list = (obj["clients"] as? [[String: Any]] ?? []).map {
                ClientInfo(
                    clientId: $0["clientId"] as? String ?? "",
                    connectedAt: $0["connectedAt"] as? Double ?? 0,
                    version: $0["version"] as? String
                )
            }
            return .clients(list)
        case "whitelist":
            let list = (obj["clients"] as? [[String: Any]] ?? []).map {
                WhitelistClient(
                    clientId: $0["clientId"] as? String ?? "",
                    token: $0["token"] as? String ?? "",
                    online: $0["online"] as? Bool ?? false
                )
            }
            return .whitelist(list, reqId: obj["reqId"] as? String)
        case "exec-output":
            return .execOutput(
                reqId: obj["reqId"] as? String ?? "",
                stream: obj["stream"] as? String ?? "stdout",
                data: obj["data"] as? String ?? "",
                targetId: obj["targetId"] as? String ?? ""
            )
        case "exec-exit":
            let code: Int?
            if let c = obj["code"] as? Int { code = c } else { code = nil }
            return .execExit(
                reqId: obj["reqId"] as? String ?? "",
                code: code,
                targetId: obj["targetId"] as? String ?? ""
            )
        case "file-content":
            return .fileContent(
                reqId: obj["reqId"] as? String ?? "",
                content: obj["content"] as? String,
                error: obj["error"] as? String,
                targetId: obj["targetId"] as? String ?? ""
            )
        case "file-listing":
            let entries = (obj["entries"] as? [[String: Any]])?.map {
                FileEntryInfo(
                    name: $0["name"] as? String ?? "",
                    kind: FileEntryKind(rawValue: $0["kind"] as? String ?? "") ?? .other,
                    size: $0["size"] as? Double ?? 0,
                    mtime: $0["mtime"] as? Double ?? 0
                )
            }
            return .fileListing(
                reqId: obj["reqId"] as? String ?? "",
                path: obj["path"] as? String ?? "",
                entries: entries,
                error: obj["error"] as? String,
                targetId: obj["targetId"] as? String ?? ""
            )
        case "done":
            return .done(
                reqId: obj["reqId"] as? String ?? "",
                ok: obj["ok"] as? Bool ?? false,
                error: obj["error"] as? String,
                targetId: obj["targetId"] as? String ?? ""
            )
        case "error":
            return .error(
                reqId: obj["reqId"] as? String,
                message: obj["message"] as? String ?? "未知错误"
            )
        case "agent-sessions":
            let sessions = (obj["sessions"] as? [[String: Any]] ?? []).map { item in
                AgentSessionInfo(
                    sessionId: item["sessionId"] as? String ?? "",
                    title: item["title"] as? String ?? "未命名会话",
                    cwd: item["cwd"] as? String,
                    state: AgentSessionState(rawValue: item["state"] as? String ?? "") ?? .failed,
                    createdAt: item["createdAt"] as? Double ?? 0,
                    updatedAt: item["updatedAt"] as? Double ?? 0,
                    error: item["error"] as? String,
                    messages: (item["messages"] as? [[String: Any]] ?? []).map {
                        AgentMessageInfo(role: $0["role"] as? String ?? "assistant", content: $0["content"] as? String ?? "", createdAt: $0["createdAt"] as? Double ?? 0)
                    }
                )
            }
            return .agentSessions(reqId: obj["reqId"] as? String ?? "", targetId: obj["targetId"] as? String ?? "", sessions: sessions)
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

    static func fileCreate(reqId: String, targetId: String, path: String) -> String {
        json(["type": "file-create", "reqId": reqId, "targetId": targetId, "path": path])
    }

    static func fileDelete(reqId: String, targetId: String, path: String) -> String {
        json(["type": "file-delete", "reqId": reqId, "targetId": targetId, "path": path])
    }

    static func fileList(reqId: String, targetId: String, path: String) -> String {
        json(["type": "file-list", "reqId": reqId, "targetId": targetId, "path": path])
    }

    static func agentList(reqId: String, targetId: String) -> String {
        json(["type": "agent-list", "reqId": reqId, "targetId": targetId])
    }

    static func agentRun(reqId: String, targetId: String, prompt: String, sessionId: String?, cwd: String?) -> String {
        var value: [String: Any] = ["type": "agent-run", "reqId": reqId, "targetId": targetId, "prompt": prompt]
        if let sessionId { value["sessionId"] = sessionId }
        if let cwd, !cwd.isEmpty { value["cwd"] = cwd }
        return json(value)
    }

    static func agentStatus(reqId: String, targetId: String, sessionId: String) -> String {
        json(["type": "agent-status", "reqId": reqId, "targetId": targetId, "sessionId": sessionId])
    }

    static func agentDelete(reqId: String, targetId: String, sessionId: String) -> String {
        json(["type": "agent-delete", "reqId": reqId, "targetId": targetId, "sessionId": sessionId])
    }

    // 白名单管理（server 直接处理，不带 targetId）
    static func listWhitelist(reqId: String) -> String {
        json(["type": "list-whitelist", "reqId": reqId])
    }

    static func clientAdd(reqId: String, clientId: String, token: String) -> String {
        json(["type": "client-add", "reqId": reqId, "clientId": clientId, "token": token])
    }

    static func clientUpdate(reqId: String, clientId: String, token: String) -> String {
        json(["type": "client-update", "reqId": reqId, "clientId": clientId, "token": token])
    }

    static func clientRemove(reqId: String, clientId: String) -> String {
        json(["type": "client-remove", "reqId": reqId, "clientId": clientId])
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
