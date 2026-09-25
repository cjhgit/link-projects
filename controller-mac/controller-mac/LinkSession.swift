import Foundation
import Observation

nonisolated enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected // ws 已建立且注册成功
}

// 全局共享配置 ~/.link-projects/controller.env（与 node 版 controller 共用，一处配置）
// 文件存在时它是唯一持久化位置：界面里改配置会写回该文件；不存在时回落到 UserDefaults
nonisolated enum SharedConfig {
    static var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    private static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".link-projects/controller.env")
    }

    static func read() -> [String: String] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    static func write(key: String, value: String) {
        var dict = read()
        dict[key] = value
        let text = dict.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n") + "\n"
        try? text.write(to: path, atomically: true, encoding: .utf8)
    }
}

// 连接 + 状态管理，行为对齐 controller/src/index.ts
@Observable
final class LinkSession: NSObject, URLSessionWebSocketDelegate {
    var serverURL: String {
        didSet { persist("LINK_SERVER", serverURL) }
    }
    var token: String {
        didSet { persist("LINK_TOKEN", token) }
    }

    private(set) var state: ConnectionState = .disconnected
    private(set) var lines: [OutputLine] = []
    private(set) var onlineClients: [ClientInfo] = []
    var currentTarget: String? {
        didSet {
            guard !initializing else { return }
            UserDefaults.standard.set(currentTarget ?? "", forKey: "LINK_TARGET")
        }
    }

    private var ws: URLSessionWebSocketTask?
    private var listRequested = false // 用户主动 /list，收到响应时打印详细列表
    private var autoConnected = false // 启动时若已配置 token 只自动连接一次，避免失败后循环重连
    private var initializing = true // init 期间的赋值不触发持久化

    private static let maxLines = 5000

    override init() {
        // 优先级：环境变量 > ~/.link-projects/controller.env > UserDefaults > 默认值
        let env = ProcessInfo.processInfo.environment
        let shared = SharedConfig.read()
        let defaults = UserDefaults.standard
        serverURL = env["LINK_SERVER"] ?? shared["LINK_SERVER"]
            ?? defaults.string(forKey: "LINK_SERVER") ?? "ws://127.0.0.1:9600"
        token = env["LINK_TOKEN"] ?? shared["LINK_TOKEN"]
            ?? defaults.string(forKey: "LINK_TOKEN") ?? ""
        currentTarget = defaults.string(forKey: "LINK_TARGET").flatMap { $0.isEmpty ? nil : $0 }
        super.init()
        initializing = false
    }

    // 全局共享文件存在时写回它（保持一处配置），否则落到 UserDefaults
    private func persist(_ key: String, _ value: String) {
        guard !initializing else { return }
        if SharedConfig.exists {
            SharedConfig.write(key: key, value: value)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    // MARK: - 连接管理

    func connect() {
        guard state == .disconnected else { return }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            append("[缺少 token，请在设置中填写]", .system)
            return
        }
        guard let url = URL(string: serverURL), url.scheme != nil else {
            append("[服务器地址无效: \(serverURL)]", .system)
            return
        }

        state = .connecting
        append("[正在连接 \(serverURL)]", .system)

        let task = URLSession.shared.webSocketTask(with: url)
        task.delegate = self
        ws = task
        task.resume()
        receiveNext()
    }

    func disconnect() {
        ws?.cancel(with: .normalClosure, reason: nil)
    }

    // 启动时若已有配置则自动连接（仅一次）
    func autoConnectIfNeeded() {
        if !autoConnected, state == .disconnected, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            autoConnected = true
            connect()
        }
    }

    private func teardown() {
        ws = nil
        state = .disconnected
        onlineClients = []
    }

    // MARK: - WebSocket 收发

    private func send(_ text: String) {
        ws?.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                self.append("[发送失败] \(message)", .system)
            }
        }
    }

    private func receiveNext() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard self.state != .disconnected else { return }
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
        append("[与服务器断开连接：\(reason)]", .system)
    }

    // MARK: - 消息处理

    private func handleMessage(_ text: String) {
        guard let msg = IncomingMessage.parse(text) else { return }

        switch msg {
        case .registered(let ok, let error):
            if !ok {
                append("[注册被拒绝] \(error ?? "未知错误")", .system)
                disconnect()
                teardown()
                return
            }
            state = .connected
            append("[已连接服务器 \(serverURL)]", .system)
            send(OutgoingMessage.listClients())

        case .clients(let clients):
            let before = onlineClients.map(\.clientId)
            let after = clients.map(\.clientId)
            onlineClients = clients
            // 当前目标掉线、或还没选且只有一台在线时，自动选择
            if let target = currentTarget, !after.contains(target) {
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
                        return "  \(cur ? "*" : " ") \(c.clientId)\(cur ? "  <- 当前" : "")"
                    }.joined(separator: "\n")
                    append("在线客户端：\n\(detail)", .system)
                }
            } else if !before.isEmpty || state == .connected, before != after {
                append("[在线客户端: \(after.joined(separator: ", "))]", .system)
            }

        case .execOutput(_, let stream, let data):
            append(Ansiless.strip(data), stream == "stderr" ? .stderr : .stdout)

        case .execExit(_, let code):
            if let code, code != 0 {
                append("[退出码 \(code)]", .system)
            }

        case .fileContent(let content, let error):
            if let error {
                append("[读取失败] \(error)", .system)
            } else {
                append(Ansiless.strip(content ?? ""), .stdout)
            }

        case .done(let ok, let error):
            append(ok ? "[写入成功]" : "[写入失败] \(error ?? "")", .system)

        case .error(let message):
            append("[错误] \(message)", .system)
        }
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
                lines.removeAll()
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

        // 其余输入作为 shell 命令下发
        guard requireTarget() else { return }
        send(OutgoingMessage.exec(reqId: newReqId(), targetId: currentTarget!, command: input))
    }

    private func requireTarget() -> Bool {
        if currentTarget != nil { return true }
        append("[请先用 /use <clientId> 选择客户端，/list 查看在线列表]", .system)
        return false
    }

    // MARK: - 工具

    private func newReqId() -> String {
        String(UUID().uuidString.prefix(8))
    }

    func clearOutput() {
        lines.removeAll()
    }

    func append(_ text: String, _ kind: OutputKind) {
        // 流式 chunk：与最后一条同类且未以换行结尾时直接续上，保持原始换行结构
        if var last = lines.last, last.kind == kind, !last.text.hasSuffix("\n"), !text.hasPrefix("\n") {
            last.text += text
            lines[lines.count - 1] = last
        } else {
            lines.append(OutputLine(kind: kind, text: text))
        }
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
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
            guard self.state == .connecting else { return }
            let clientId = String(UUID().uuidString.prefix(8))
            self.send(OutgoingMessage.register(clientId: clientId, token: self.token))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            self.handleDisconnected("连接已关闭")
        }
    }
}
