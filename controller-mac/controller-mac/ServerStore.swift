import Foundation
import Observation

// 服务端配置：控制端可同时管理多个服务端，客户端归属各自的服务端
nonisolated struct Server: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var url = ""
    var token = ""

    // 名称为空时用地址里的 host 展示
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url.isEmpty ? "未命名服务器" : url
    }
}

// 添加 / 编辑服务器弹窗状态
enum ServerSheet: Identifiable {
    case add
    case edit(Server)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let server): return "edit-\(server.id.uuidString)"
        }
    }
}

// 全局共享配置 ~/.link-projects/controller.env（与 node 版 controller 共用）
// 多服务端列表存于 UserDefaults，本文件现仅用于首次启动时迁移旧的单服务端配置
nonisolated enum SharedConfig {
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
}

// 多服务端管理：服务端列表 + 每个服务端一个 LinkSession（连接、客户端、输出各自独立）
@Observable
final class AppModel {
    private(set) var servers: [Server] = []
    private(set) var sessions: [UUID: LinkSession] = [:]
    var serverSheet: ServerSheet?
    var selectedServerId: UUID? {
        didSet {
            guard !initializing else { return }
            UserDefaults.standard.set(selectedServerId?.uuidString ?? "", forKey: Self.selectedKey)
        }
    }

    private var initializing = true // init 期间的赋值不触发持久化
    private static let serversKey = "LINK_SERVERS"
    private static let selectedKey = "LINK_SELECTED_SERVER"

    var selectedServer: Server? { servers.first { $0.id == selectedServerId } }
    var selectedSession: LinkSession? { selectedServerId.flatMap { sessions[$0] } }

    init() {
        loadServers()
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: raw),
           servers.contains(where: { $0.id == id }) {
            selectedServerId = id
        }
        if selectedServerId == nil {
            selectedServerId = servers.first?.id
        }
        for server in servers {
            sessions[server.id] = LinkSession(server: server)
        }
        initializing = false
    }

    // MARK: - 持久化与迁移

    private func loadServers() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.serversKey),
           let list = try? JSONDecoder().decode([Server].self, from: data) {
            servers = list // key 已存在（即使为空）说明完成过初始化，不再迁移
            return
        }
        // 首次启动：从旧的单服务端配置迁移（环境变量 > 共享配置文件 > 旧 UserDefaults）
        let env = ProcessInfo.processInfo.environment
        let shared = SharedConfig.read()
        let legacyURL = env["LINK_SERVER"] ?? shared["LINK_SERVER"] ?? defaults.string(forKey: "LINK_SERVER")
        let legacyToken = env["LINK_TOKEN"] ?? shared["LINK_TOKEN"] ?? defaults.string(forKey: "LINK_TOKEN")
        guard let legacyURL, !legacyURL.isEmpty else { return }
        let server = Server(name: "", url: legacyURL, token: legacyToken ?? "")
        servers = [server]
        if let legacyTarget = defaults.string(forKey: "LINK_TARGET"), !legacyTarget.isEmpty {
            LinkSession.migrateLegacyTarget(legacyTarget, to: server)
        }
        persistServers()
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }

    // MARK: - 服务端管理

    func addServer(name: String, url: String, token: String) {
        let server = Server(name: name, url: url, token: token)
        servers.append(server)
        persistServers()
        let session = LinkSession(server: server)
        sessions[server.id] = session
        selectedServerId = server.id
        if !token.isEmpty { session.connect() }
    }

    func updateServer(_ server: Server) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let old = servers[index]
        servers[index] = server
        persistServers()
        guard let session = sessions[server.id] else { return }
        session.server = server
        // 已连接且地址/Token 变更时重连；仅改名等不影响现有连接
        if session.state != .disconnected, old.url != server.url || old.token != server.token {
            session.reconnect()
        }
    }

    func removeServer(_ server: Server) {
        sessions[server.id]?.disconnect()
        sessions[server.id] = nil
        servers.removeAll { $0.id == server.id }
        LinkSession.removeSavedTarget(for: server)
        persistServers()
        if selectedServerId == server.id {
            selectedServerId = servers.first?.id
        }
    }

    // MARK: - 连接

    // 启动时对所有已配置 token 的服务端各自动连接一次（失败不重试）
    func connectAllIfNeeded() {
        for session in sessions.values {
            session.autoConnectIfNeeded()
        }
    }

    func state(of server: Server) -> ConnectionState {
        sessions[server.id]?.state ?? .disconnected
    }
}
