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

// 添加 / 编辑客户端弹窗状态（client 为 nil = 新增），携带目标服务端的会话
struct ClientEditSheet: Identifiable {
    let session: LinkSession
    let client: WhitelistClient? // nil = 新增
    let id = UUID()
}

// 多服务端管理：服务端列表 + 每个服务端一个 LinkSession（连接、客户端、输出各自独立）
@Observable
final class AppModel {
    private(set) var servers: [Server] = []
    private(set) var sessions: [UUID: LinkSession] = [:]
    var serverSheet: ServerSheet?
    var clientEditSheet: ClientEditSheet?
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

    // MARK: - 持久化

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: Self.serversKey),
              let list = try? JSONDecoder().decode([Server].self, from: data) else { return }
        servers = list
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

    // 回到前台时把「非手动断开」的会话自动重连（锁屏/切后台后 ws 常被系统断开）
    func reconnectOnForeground() {
        for session in sessions.values {
            session.connectIfIdle()
        }
    }

    func state(of server: Server) -> ConnectionState {
        sessions[server.id]?.state ?? .disconnected
    }
}
