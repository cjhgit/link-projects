import Foundation
import Observation

nonisolated enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected // ws 已建立且注册成功
}

// 单个服务端的连接 + 状态管理，行为对齐 controller/src/index.ts
// 每个服务端一个实例：在线客户端、按客户端分流的输出、目标选择各自独立
@Observable
final class LinkSession: NSObject, URLSessionWebSocketDelegate {
    // 保留目标：指向 server 本机（执行命令 / 浏览文件），server 端拦截不转发
    static let serverTargetId = "@server"

    var server: Server // 编辑服务器时更新，连接时取其 url/token

    private(set) var state: ConnectionState = .disconnected
    // server 通过 registered 下发的自身版本（package.json），旧版 server 不下发；断开后保留展示
    private(set) var serverVersion: String?
    // 输出按客户端分流（key = clientId，"" 为公共区：连接状态等与具体客户端无关的消息）
    // 当前查看区由 currentTarget 决定，切换客户端时右侧只显示各自的内容
    private(set) var outputs: [String: [OutputLine]] = [:]
    var lines: [OutputLine] { outputs[currentTarget ?? ""] ?? [] }
    private(set) var onlineClients: [ClientInfo] = []
    // 服务端白名单全量列表（连接后推送 / 变更后广播刷新，断开不清空以便管理界面继续查看）
    private(set) var whitelist: [WhitelistClient] = []
    var currentTarget: String? {
        didSet {
            guard !initializing else { return }
            Self.saveTarget(currentTarget, for: server.id)
        }
    }

    private var ws: URLSessionWebSocketTask?
    private var listRequested = false // 用户主动 /list，收到响应时打印详细列表
    private var autoConnected = false // 启动时若已配置 token 只自动连接一次，避免失败后循环重连
    private var initializing = true // init 期间的赋值不触发持久化
    private var outputReqIds: Set<String> = [] // 收到过输出的请求，exec 结束时据此判断是否 [无输出]
    // 白名单管理请求的回调（reqId -> 回执），done/error 按此路由到管理界面而非终端
    private var manageCallbacks: [String: (String?) -> Void] = [:]
    // 文件操作请求的回调（reqId -> 回执），file-listing/file-content/done/error 按此路由到文件界面
    private var fileCallbacks: [String: (FileReply) -> Void] = [:]
    // Agent 请求同样以 reqId 关联，断线后不会依赖回调；界面可重新拉取 client 本机快照。
    private var agentCallbacks: [String: ([AgentSessionInfo]) -> Void] = [:]
    private var agentUpdateHandlers: [String: ([AgentSessionInfo]) -> Void] = [:]

    private static let maxLines = 5000
    private static let targetsKey = "LINK_TARGETS" // 每个服务端各自记住的目标客户端 [serverId: clientId]

    init(server: Server) {
        self.server = server
        currentTarget = Self.savedTarget(for: server.id)
        super.init()
        initializing = false
    }

    // MARK: - 目标客户端持久化（按服务端独立记忆，切换服务端互不影响）

    private static func savedTargets() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: targetsKey) as? [String: String] ?? [:]
    }

    private static func saveTarget(_ target: String?, for serverId: UUID) {
        var targets = savedTargets()
        if let target, !target.isEmpty {
            targets[serverId.uuidString] = target
        } else {
            targets[serverId.uuidString] = nil
        }
        UserDefaults.standard.set(targets, forKey: targetsKey)
    }

    private static func savedTarget(for serverId: UUID) -> String? {
        let value = savedTargets()[serverId.uuidString]
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func removeSavedTarget(for server: Server) {
        saveTarget(nil, for: server.id)
    }

    static func migrateLegacyTarget(_ target: String, to server: Server) {
        saveTarget(target, for: server.id)
    }

    // MARK: - 连接管理

    func connect() {
        guard state == .disconnected else { return }
        let trimmedToken = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            append("[缺少 token，请编辑服务器填写]", .system, to: "")
            return
        }
        guard let url = URL(string: server.url), url.scheme != nil else {
            append("[服务器地址无效: \(server.url)]", .system, to: "")
            return
        }

        state = .connecting
        append("[正在连接 \(server.displayName)]", .system, to: "")

        let task = URLSession.shared.webSocketTask(with: url)
        task.delegate = self
        ws = task
        task.resume()
        receiveNext()
    }

    func disconnect() {
        ws?.cancel(with: .normalClosure, reason: nil)
    }

    // 编辑服务器（地址/Token 变更）后重连：disconnect 是异步回调，直接 connect 会被 state 拦截，
    // 这里先强制复位旧连接再拨新的；旧连接的残余回调由 task 身份校验过滤
    func reconnect() {
        ws?.cancel(with: .normalClosure, reason: nil)
        teardown()
        connect()
    }

    // 启动时若已配置则自动连接（仅一次，由 AppModel 对所有服务端统一触发）
    func autoConnectIfNeeded() {
        if !autoConnected, state == .disconnected, !server.token.isEmpty {
            autoConnected = true
            connect()
        }
    }

    private func teardown() {
        ws = nil
        state = .disconnected
        onlineClients = []
        // 管理类请求不会再有回执，统一以失败回调，避免管理界面一直等待
        let pending = manageCallbacks
        manageCallbacks.removeAll()
        for callback in pending.values { callback("连接已断开") }
        // 文件操作同理
        let pendingFiles = fileCallbacks
        fileCallbacks.removeAll()
        for callback in pendingFiles.values { callback(.failure("连接已断开")) }
        agentCallbacks.removeAll()
        agentUpdateHandlers.removeAll()
    }

    // MARK: - WebSocket 收发

    private func send(_ text: String) {
        ws?.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                self.append("[发送失败] \(message)", .system, to: "")
            }
        }
    }

    private func receiveNext() {
        guard let task = ws else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                // 重连后旧连接的回调直接丢弃
                guard self.ws === task, self.state != .disconnected else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default: break
                    }
                    self.receiveNext()
                case .failure(let error):
                    self.handleDisconnected(error.localizedDescription)
                }
            }
        }
    }

    private func handleDisconnected(_ reason: String) {
        guard state != .disconnected else { return }
        teardown()
        append("[与服务器断开连接：\(reason)]", .system, to: "")
    }

    // MARK: - 消息处理

    private func handleMessage(_ text: String) {
        guard let msg = IncomingMessage.parse(text) else { return }

        switch msg {
        case .registered(let ok, let error, let serverVersion):
            if !ok {
                append("[注册被拒绝] \(error ?? "未知错误")", .system, to: "")
                disconnect()
                teardown()
                return
            }
            state = .connected
            self.serverVersion = serverVersion
            let versionSuffix = serverVersion.map { "（v\($0)）" } ?? ""
            append("[已连接服务器 \(server.displayName)\(versionSuffix)]", .system, to: "")
            send(OutgoingMessage.listClients())

        case .clients(let clients):
            let before = onlineClients.map(\.clientId)
            let after = clients.map(\.clientId)
            onlineClients = clients
            // 统一列表后目标可指向离线客户端（行仍可见），仅当其被移出白名单时才重置；
            // 保留目标 @server 不参与该重置；还没选且只有一台在线时自动选择
            let whitelistIds = Set(whitelist.map(\.clientId))
            if let target = currentTarget, target != Self.serverTargetId, !after.contains(target), !whitelistIds.contains(target) {
                currentTarget = after.count == 1 ? after[0] : nil
            } else if currentTarget == nil, after.count == 1 {
                currentTarget = after[0]
            }
            // 主动 /list 时打印详细列表；线路变化时只打印摘要
            if listRequested {
                listRequested = false
                if after.isEmpty {
                    append("[无在线客户端]", .system)
                } else {
                    let detail = clients.map { c in
                        let cur = c.clientId == currentTarget
                        let version = c.version.map { " (v\($0))" } ?? ""
                        return "  \(cur ? "*" : " ") \(c.clientId)\(version)\(cur ? "  <- 当前" : "")"
                    }.joined(separator: "\n")
                    append("在线客户端：\n\(detail)", .system)
                }
                appendSeparator()
            } else if !before.isEmpty || state == .connected, before != after {
                append("[在线客户端: \(after.joined(separator: ", "))]", .system)
            }

        case .whitelist(let clients, let reqId):
            whitelist = clients
            // list-whitelist 的主动请求：通知发起方已拿到列表
            if let reqId, let callback = manageCallbacks.removeValue(forKey: reqId) {
                callback(nil)
            }

        case .execOutput(let reqId, let stream, let data, let targetId):
            outputReqIds.insert(reqId)
            append(Ansiless.strip(data), stream == "stderr" ? .stderr : .stdout, to: targetId)

        case .execExit(let reqId, let code, let targetId):
            // 整个过程没有任何 stdout/stderr 时明确提示，避免误以为卡住
            if outputReqIds.remove(reqId) == nil {
                append("[无输出]", .system, to: targetId)
            }
            if let code, code != 0 {
                append("[退出码 \(code)]", .system, to: targetId)
            }
            appendSeparator(to: targetId)

        case .fileContent(let reqId, let content, let error, let targetId):
            // 文件界面的读取请求：路由到回调，不进终端
            if let callback = fileCallbacks.removeValue(forKey: reqId) {
                if let error {
                    callback(.failure(error))
                } else if let content {
                    callback(.content(content))
                } else {
                    callback(.failure("空响应"))
                }
                return
            }
            // 终端 /read 命令
            if let error {
                append("[读取失败] \(error)", .system, to: targetId)
            } else if Ansiless.strip(content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append("[无输出]", .system, to: targetId)
            } else {
                append(Ansiless.strip(content ?? ""), .stdout, to: targetId)
            }
            appendSeparator(to: targetId)

        case .fileListing(let reqId, let path, let entries, let error, _):
            // file-list 只有文件界面发起，响应一律路由到回调
            if let callback = fileCallbacks.removeValue(forKey: reqId) {
                if let error {
                    callback(.failure(error))
                } else if let entries {
                    callback(.listing(path: path, entries: entries))
                } else {
                    callback(.failure("空响应"))
                }
            }

        case .done(let reqId, let ok, let error, let targetId):
            // 白名单管理类回执：路由到管理界面，不进终端
            if let callback = manageCallbacks.removeValue(forKey: reqId) {
                callback(ok ? nil : (error ?? "操作失败"))
                return
            }
            // 文件界面的写入回执
            if let callback = fileCallbacks.removeValue(forKey: reqId) {
                callback(.ack(ok: ok, error: error))
                return
            }
            append(ok ? "[写入成功]" : "[写入失败] \(error ?? "")", .system, to: targetId)
            appendSeparator(to: targetId)

        case .error(let reqId, let message):
            if let reqId, let callback = manageCallbacks.removeValue(forKey: reqId) {
                callback(message)
                return
            }
            if let reqId, let callback = fileCallbacks.removeValue(forKey: reqId) {
                callback(.failure(message))
                return
            }
            append("[错误] \(message)", .system)
            appendSeparator()

        case .agentSessions(let reqId, let targetId, let sessions):
            if let callback = agentCallbacks.removeValue(forKey: reqId) { callback(sessions) }
            else { agentUpdateHandlers[targetId]?(sessions) }
        }
    }

    // MARK: - Claude Code 会话（会话数据在 client 本机持久化，不在 server 保存）

    func listAgentSessions(targetId: String, completion: @escaping ([AgentSessionInfo]) -> Void) {
        guard state == .connected else { completion([]); return }
        let reqId = UUID().uuidString
        agentCallbacks[reqId] = completion
        send(OutgoingMessage.agentList(reqId: reqId, targetId: targetId))
    }

    func runAgent(targetId: String, prompt: String, sessionId: String? = nil, cwd: String? = nil, completion: @escaping ([AgentSessionInfo]) -> Void) {
        guard state == .connected else { completion([]); return }
        let reqId = UUID().uuidString
        agentCallbacks[reqId] = completion
        send(OutgoingMessage.agentRun(reqId: reqId, targetId: targetId, prompt: prompt, sessionId: sessionId, cwd: cwd))
    }

    func agentStatus(targetId: String, sessionId: String, completion: @escaping ([AgentSessionInfo]) -> Void) {
        guard state == .connected else { completion([]); return }
        let reqId = UUID().uuidString
        agentCallbacks[reqId] = completion
        send(OutgoingMessage.agentStatus(reqId: reqId, targetId: targetId, sessionId: sessionId))
    }

    func observeAgentUpdates(targetId: String, handler: @escaping ([AgentSessionInfo]) -> Void) {
        agentUpdateHandlers[targetId] = handler
    }

    func stopObservingAgentUpdates(targetId: String) {
        agentUpdateHandlers[targetId] = nil
    }

    func deleteAgentSession(targetId: String, sessionId: String, completion: @escaping ([AgentSessionInfo]) -> Void) {
        guard state == .connected else { completion([]); return }
        let reqId = UUID().uuidString
        agentCallbacks[reqId] = completion
        send(OutgoingMessage.agentDelete(reqId: reqId, targetId: targetId, sessionId: sessionId))
    }

    // MARK: - 输入处理（对齐 handleLine）

    // 查询在线列表（/list 与侧边栏刷新共用）
    func submitList() {
        guard state == .connected else { return }
        listRequested = true
        send(OutgoingMessage.listClients())
    }

    func submit(_ raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        append("\(currentTarget ?? "(未选择)")> \(input)", .command)

        guard state == .connected else {
            append("[未连接服务器]", .system)
            return
        }

        // 本地命令以 / 开头
        if input.hasPrefix("/") {
            let parts = input.dropFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let cmd = parts.first ?? ""
            let rest = Array(parts.dropFirst())

            switch cmd {
            case "list":
                submitList()
            case "use":
                let id = rest.joined(separator: " ")
                guard !id.isEmpty else {
                    append("用法: /use <clientId>", .system)
                    return
                }
                if !onlineClients.contains(where: { $0.clientId == id }) {
                    append("[注意] \(id) 不在当前在线列表中，仍会尝试发送", .system)
                }
                currentTarget = id
                append("[已选择 \(id)]", .system)
            case "read":
                guard requireTarget() else { return }
                let path = rest.joined(separator: " ")
                guard !path.isEmpty else {
                    append("用法: /read <远程路径>", .system)
                    return
                }
                send(OutgoingMessage.fileRead(reqId: newReqId(), targetId: currentTarget!, path: path))
            case "write":
                guard requireTarget() else { return }
                guard let path = rest.first, !path.isEmpty else {
                    append("用法: /write <远程路径> <内容>", .system)
                    return
                }
                // 内容 = 路径之后的原文（保留内容中的空格）
                guard let pathRange = input.range(of: path, range: input.startIndex..<input.endIndex) else { return }
                let content = String(input[pathRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else {
                    append("用法: /write <远程路径> <内容>", .system)
                    return
                }
                send(OutgoingMessage.fileWrite(reqId: newReqId(), targetId: currentTarget!, path: path, content: content))
            case "clear":
                clearOutput()
            case "help":
                append(
                    """
                    命令：
                      /list               查看在线客户端
                      /use <id>           选择要控制的客户端（也可点击左侧列表）
                      /read <路径>         读取远程文件
                      /write <路径> <内容>  写入远程文件
                      /clear              清空输出
                      其他任意输入          作为 shell 命令在客户端执行（实时输出）
                    """,
                    .system
                )
            default:
                append("未知命令 \(cmd)，/help 查看帮助", .system)
            }
            return
        }

        // 其余输入作为 shell 命令下发（客户端与服务器主机目标均在远端执行）
        guard requireTarget() else { return }
        send(OutgoingMessage.exec(reqId: newReqId(), targetId: currentTarget!, command: input))
    }

    private func requireTarget() -> Bool {
        if currentTarget != nil { return true }
        append("[请先用 /use <clientId> 选择客户端，/list 查看在线列表]", .system)
        return false
    }

    // 目标的展示名：@server 显示为「服务器主机」，其余为 clientId（终端提示符 / 选择提示用）
    var currentTargetDisplay: String {
        guard let target = currentTarget else { return "(未选择)" }
        return target == Self.serverTargetId ? "服务器主机" : target
    }

    // MARK: - 文件操作（对当前目标客户端，回执经 fileCallbacks 路由到文件界面）

    /// 列出远程目录；path 为空或 ~ 表示客户端家目录，成功返回展开后的实际路径
    func listFiles(path: String, completion: @escaping (FileOutcome<(path: String, entries: [FileEntryInfo])>) -> Void) {
        guard state == .connected else { return completion(.failed("未连接服务器")) }
        guard let target = currentTarget else { return completion(.failed("未选择客户端")) }
        let reqId = newReqId()
        fileCallbacks[reqId] = { reply in
            switch reply {
            case .listing(let path, let entries):
                completion(.ok((path, entries)))
            case .failure(let error):
                completion(.failed(error))
            default:
                completion(.failed("意外响应"))
            }
        }
        send(OutgoingMessage.fileList(reqId: reqId, targetId: target, path: path))
    }

    /// 读取远程文本文件内容
    func readRemoteFile(path: String, completion: @escaping (FileOutcome<String>) -> Void) {
        guard state == .connected else { return completion(.failed("未连接服务器")) }
        guard let target = currentTarget else { return completion(.failed("未选择客户端")) }
        let reqId = newReqId()
        fileCallbacks[reqId] = { reply in
            switch reply {
            case .content(let content):
                completion(.ok(content))
            case .failure(let error):
                completion(.failed(error))
            default:
                completion(.failed("意外响应"))
            }
        }
        send(OutgoingMessage.fileRead(reqId: reqId, targetId: target, path: path))
    }

    /// 写入远程文件；completion 参数为 nil 表示成功，否则为错误信息
    func writeRemoteFile(path: String, content: String, completion: @escaping (String?) -> Void) {
        guard state == .connected else { return completion("未连接服务器") }
        guard let target = currentTarget else { return completion("未选择客户端") }
        let reqId = newReqId()
        fileCallbacks[reqId] = { reply in
            switch reply {
            case .ack(let ok, let error):
                completion(ok ? nil : (error ?? "写入失败"))
            case .failure(let error):
                completion(error)
            default:
                completion("意外响应")
            }
        }
        send(OutgoingMessage.fileWrite(reqId: reqId, targetId: target, path: path, content: content))
    }

    /// 在远端新建空文本文件（已存在则失败，不覆盖已有内容）；completion 参数为 nil 表示成功，否则为错误信息
    func createRemoteFile(path: String, completion: @escaping (String?) -> Void) {
        guard state == .connected else { return completion("未连接服务器") }
        guard let target = currentTarget else { return completion("未选择客户端") }
        let reqId = newReqId()
        fileCallbacks[reqId] = { reply in
            switch reply {
            case .ack(let ok, let error):
                completion(ok ? nil : (error ?? "新建失败"))
            case .failure(let error):
                completion(error)
            default:
                completion("意外响应")
            }
        }
        send(OutgoingMessage.fileCreate(reqId: reqId, targetId: target, path: path))
    }

    /// 删除远程文件或目录（目录递归删除）；completion 参数为 nil 表示成功，否则为错误信息
    func deleteRemoteFile(path: String, completion: @escaping (String?) -> Void) {
        guard state == .connected else { return completion("未连接服务器") }
        guard let target = currentTarget else { return completion("未选择客户端") }
        let reqId = newReqId()
        fileCallbacks[reqId] = { reply in
            switch reply {
            case .ack(let ok, let error):
                completion(ok ? nil : (error ?? "删除失败"))
            case .failure(let error):
                completion(error)
            default:
                completion("意外响应")
            }
        }
        send(OutgoingMessage.fileDelete(reqId: reqId, targetId: target, path: path))
    }

    // MARK: - 客户端白名单管理（发给 server 直接处理，回执经 manageCallbacks 路由）

    /// 拉取白名单；completion 参数为 nil 表示成功（列表已更新到 whitelist）
    func refreshWhitelist(_ completion: ((String?) -> Void)? = nil) {
        guard state == .connected else {
            completion?("未连接服务器")
            return
        }
        let reqId = newReqId()
        if let completion { manageCallbacks[reqId] = completion }
        send(OutgoingMessage.listWhitelist(reqId: reqId))
    }

    /// 新增客户端；completion 参数为 nil 表示成功，否则为错误信息
    func addClient(clientId: String, token: String, completion: @escaping (String?) -> Void) {
        guard state == .connected else { return completion("未连接服务器") }
        let reqId = newReqId()
        manageCallbacks[reqId] = completion
        send(OutgoingMessage.clientAdd(reqId: reqId, clientId: clientId, token: token))
    }

    /// 更新客户端 token（不影响已建立的连接，重连后生效）
    func updateClient(clientId: String, token: String, completion: @escaping (String?) -> Void) {
        guard state == .connected else { return completion("未连接服务器") }
        let reqId = newReqId()
        manageCallbacks[reqId] = completion
        send(OutgoingMessage.clientUpdate(reqId: reqId, clientId: clientId, token: token))
    }

    /// 删除客户端（服务端会同步断开其在线连接）
    func removeClient(clientId: String, completion: @escaping (String?) -> Void) {
        guard state == .connected else { return completion("未连接服务器") }
        let reqId = newReqId()
        manageCallbacks[reqId] = completion
        send(OutgoingMessage.clientRemove(reqId: reqId, clientId: clientId))
    }

    // MARK: - 工具

    // 统一客户端列表 = 白名单全体 + 实时在线状态（在线在前，其余按名称排序）。
    // 旧版 server 不下发白名单时，把在线客户端并入（token 为 nil：可查看选择，不可编辑删除），
    // 避免升级过渡期中间列空白
    var clientRows: [ClientRow] {
        let onlineIds = Set(onlineClients.map(\.clientId))
        // 在线客户端的版本表（有版本必然在线，在线未必有版本：旧版 client 不上报）
        let onlineVersions = [String: String](onlineClients.compactMap { c in
            c.version.map { (c.clientId, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var rows = whitelist.map { client in
            ClientRow(
                clientId: client.clientId,
                token: client.token,
                online: onlineIds.contains(client.clientId),
                version: onlineVersions[client.clientId]
            )
        }
        let knownIds = Set(whitelist.map(\.clientId))
        for id in onlineIds where !knownIds.contains(id) {
            rows.append(ClientRow(clientId: id, token: nil, online: true, version: onlineVersions[id]))
        }
        return rows.sorted {
            if $0.online != $1.online { return $0.online }
            return $0.clientId.localizedStandardCompare($1.clientId) == .orderedAscending
        }
    }

    private func newReqId() -> String {
        String(UUID().uuidString.prefix(8))
    }

    func clearOutput() {
        // 只清当前查看区（各客户端输出相互独立）
        outputs[currentTarget ?? ""] = nil
    }

    // to 为 nil 时写入当前查看区；连接生命周期消息传 to: "" 写公共区
    func append(_ text: String, _ kind: OutputKind, to target: String? = nil) {
        let key = target ?? currentTarget ?? ""
        var buffer = outputs[key] ?? []
        // 流式 chunk：与最后一条同类且未以换行结尾时直接续上，保持原始换行结构
        // （separator 独立成行，不参与续接）
        if var last = buffer.last, last.kind == kind, !last.text.hasSuffix("\n"), !text.hasPrefix("\n") {
            last.text += text
            buffer[buffer.count - 1] = last
        } else {
            buffer.append(OutputLine(kind: kind, text: text))
        }
        if buffer.count > Self.maxLines {
            buffer.removeFirst(buffer.count - Self.maxLines)
        }
        outputs[key] = buffer
    }

    // 每次交互（命令 / 读写 / 列表）结束时输出，便于区分各次输入输出
    private func appendSeparator(to target: String? = nil) {
        append(String(repeating: "─", count: 40), .separator, to: target)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LinkSession {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            // 重连后旧连接的回调直接丢弃
            guard self.state == .connecting, self.ws === webSocketTask else { return }
            let clientId = String(UUID().uuidString.prefix(8))
            self.send(OutgoingMessage.register(clientId: clientId, token: self.server.token))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            guard self.ws === webSocketTask else { return }
            self.handleDisconnected("连接已关闭")
        }
    }
}
