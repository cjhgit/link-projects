import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ServerSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            ClientSidebar()
                .navigationSplitViewColumnWidth(min: 160, ideal: 210)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 880, minHeight: 460)
        .persistedSplitView("main-navigation-columns")
        .sheet(item: $model.serverSheet) { sheet in
            ServerSheetView(sheet: sheet)
        }
        .sheet(item: $model.clientEditSheet) { sheet in
            ClientEditView(session: sheet.session, client: sheet.client)
        }
        .onAppear { model.connectAllIfNeeded() }
    }
}

// MARK: - 服务端列表（多服务端：选中哪个，中间列的客户端与右侧终端就归属哪个）

private struct ServerSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: Server?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedServerId) {
            ForEach(model.servers) { server in
                serverRow(server)
                    .tag(server.id)
            }
        }
        .overlay {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("未添加服务器", systemImage: "server.rack")
                } description: {
                    Text("添加后可同时管理多个服务端")
                } actions: {
                    Button("添加服务器") { model.serverSheet = .add }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("服务器（\(model.servers.count)）")
                    .font(.headline)
                Spacer()
                Button {
                    model.serverSheet = .add
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加服务器")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            "删除服务器",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .automatic,
            presenting: confirmDelete
        ) { server in
            Button("删除“\(server.displayName)”", role: .destructive) {
                model.removeServer(server)
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        } message: { _ in
            Text("将断开该服务器的连接并移除其配置")
        }
    }

    private func serverRow(_ server: Server) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(model.state(of: server)))
                .frame(width: 6, height: 6)
            Text(server.displayName)
                .lineLimit(1)
            if let version = model.sessions[server.id]?.serverVersion {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("服务端版本")
            }
            Spacer()
            if let session = model.sessions[server.id], session.state == .connected {
                Text("\(session.onlineClients.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("在线客户端数")
            }
        }
        .contextMenu {
            if let session = model.sessions[server.id] {
                if session.state == .disconnected {
                    Button("连接") { session.connect() }
                } else {
                    Button("断开连接") { session.disconnect() }
                }
            }
            Divider()
            Button("编辑…") { model.serverSheet = .edit(server) }
            Button("删除…", role: .destructive) { confirmDelete = server }
        }
    }

    private func statusColor(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .secondary.opacity(0.5)
        }
    }
}

// MARK: - 当前服务端的客户端（白名单全体，在线只是状态；选中即 /use，不同服务端客户端各自独立）

private struct ClientSidebar: View {
    @Environment(AppModel.self) private var model
    // 删除确认携带发起时的会话，避免弹窗期间切换服务端后误删到别的服务端
    @State private var confirmDelete: (session: LinkSession, client: WhitelistClient)?

    var body: some View {
        if let session = model.selectedSession {
            let rows = session.clientRows
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { session.currentTarget },
                    set: { id in
                        if let id, id != session.currentTarget {
                            session.currentTarget = id
                            if id == LinkSession.serverTargetId {
                                session.append("[已选择 服务器主机，终端与「文件」页签直接操作 server 本机]", .system)
                            } else {
                                let online = session.onlineClients.contains { $0.clientId == id }
                                session.append("[已选择 \(id)\(online ? "" : "（离线）")]", .system)
                            }
                        }
                    }
                )) {
                    serverHostRow(session: session)
                    ForEach(rows) { row in
                        clientRow(row, session: session)
                    }
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView(
                            session.state == .connected ? "未登记客户端" : "未连接",
                            systemImage: "desktopcomputer.and.iphone",
                            description: Text(session.state == .connected ? "点右上角 + 登记第一台客户端" : "请先连接该服务器")
                        )
                    }
                }
                // 未连接但仍有上次同步的白名单时，列表照常展示（全灰点），底部说明原因
                if session.state != .connected, !rows.isEmpty {
                    Divider()
                    Text("未连接，显示上次同步的白名单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("客户端（在线 \(rows.filter(\.online).count)/\(rows.count)）")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.clientEditSheet = ClientEditSheet(session: session, client: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("登记客户端到白名单")
                    .disabled(session.state != .connected)
                    Button {
                        if session.state == .connected {
                            session.append("/list", .command)
                            session.submitList()
                            session.refreshWhitelist { error in
                                if let error {
                                    session.append("[刷新白名单失败] \(error)", .system, to: "")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新客户端状态")
                    .disabled(session.state != .connected)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .confirmationDialog(
                "删除客户端",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                presenting: confirmDelete
            ) { item in
                Button("删除“\(item.client.clientId)”", role: .destructive) {
                    delete(item)
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: { _ in
                Text("将从服务端白名单移除，在线连接会被立即断开，该机器此后无法再注册接入")
            }
        } else {
            ContentUnavailableView(
                "未选择服务器",
                systemImage: "server.rack",
                description: Text(model.servers.isEmpty ? "请先添加服务器" : "请在左侧选择服务器")
            )
        }
    }

    // 固定首行：服务器主机（@server 保留目标），选中后「文件」页签即浏览 server 本机文件
    private func serverHostRow(session: LinkSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.state == .connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .help(session.state == .connected ? "已连接" : "未连接")
            Image(systemName: "server.rack")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("服务器主机")
                .lineLimit(1)
            if let version = session.serverVersion {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("服务端版本")
            }
            if session.currentTarget == LinkSession.serverTargetId {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(LinkSession.serverTargetId)
        .help("选中后终端可对 server 本机执行命令，「文件」页签浏览其文件")
    }

    private func clientRow(_ row: ClientRow, session: LinkSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(row.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .help(row.online ? "在线" : "离线")
            Text(row.clientId)
                .lineLimit(1)
            if let version = row.version {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("客户端版本")
            }
            if row.clientId == session.currentTarget {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(row.clientId)
        .contextMenu {
            Button("拷贝 ID") { copy(row.clientId) }
            // token 为 nil 的回退行（旧版 server）没有白名单数据，不提供管理项
            if let token = row.token, !token.isEmpty {
                Button("拷贝 Token") { copy(token) }
                Button("拷贝接入配置（.env）") {
                    copy("LINK_SERVER=\(session.server.url)\nLINK_CLIENT_ID=\(row.clientId)\nLINK_TOKEN=\(token)")
                }
                Divider()
                Button("编辑…") {
                    model.clientEditSheet = ClientEditSheet(
                        session: session,
                        client: WhitelistClient(clientId: row.clientId, token: token, online: row.online)
                    )
                }
                .disabled(session.state != .connected)
                Button("删除…", role: .destructive) {
                    confirmDelete = (session, WhitelistClient(clientId: row.clientId, token: token, online: row.online))
                }
                .disabled(session.state != .connected)
            }
        }
    }

    private func delete(_ item: (session: LinkSession, client: WhitelistClient)) {
        item.session.removeClient(clientId: item.client.clientId) { error in
            if let error {
                item.session.append("[删除客户端失败] \(error)", .system, to: "")
            } else {
                item.session.append("[已删除客户端 \(item.client.clientId)，在线连接已断开]", .system, to: "")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 详情区：已连接显示终端，否则显示连接入口

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.servers.isEmpty {
            ContentUnavailableView {
                Label("未添加服务器", systemImage: "server.rack")
            } description: {
                Text("支持同时连接多个服务端，各服务端的客户端独立管理")
            } actions: {
                Button("添加服务器") { model.serverSheet = .add }
            }
        } else if let session = model.selectedSession {
            if session.state == .connected {
                WorkspaceView(session: session)
            } else {
                ConnectView(session: session)
            }
        } else {
            ContentUnavailableView(
                "未选择服务器",
                systemImage: "server.rack",
                description: Text("请在左侧选择服务器")
            )
        }
    }
}

// MARK: - 单个服务端的连接页（未连接时显示，可连接 / 编辑）

private struct ConnectView: View {
    @Environment(AppModel.self) private var model
    let session: LinkSession

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(session.server.displayName)
                .font(.title2.bold())
            Text(session.server.url)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let version = session.serverVersion {
                Text("服务端版本 v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch session.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("连接中…")
                }
            case .disconnected:
                HStack {
                    Button("连接") { session.connect() }
                        .controlSize(.large)
                    Button("编辑…") { model.serverSheet = .edit(session.server) }
                }
            case .connected:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // 连接失败会弹回本页，公共区最近一条系统提示（失败原因）显示在这里
            if let lastError = (session.outputs[""] ?? []).last(where: { $0.kind == .system }) {
                Text(lastError.text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - 添加 / 编辑服务器

private struct ServerSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheet: ServerSheet

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(title) {
                    TextField("名称（可选，默认用地址）", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("地址（ws://host:port）", text: $url)
                        .textFieldStyle(.roundedBorder)
                    TextField("Token（服务端 CONTROLLER_TOKEN）", text: $token)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 480, height: 300)
        .onAppear {
            if case .edit(let server) = sheet {
                name = server.name
                url = server.url
                token = server.token
            }
        }
    }

    private var title: String {
        if case .add = sheet { return "添加服务器" }
        return "编辑服务器"
    }

    private var saveTitle: String {
        if case .add = sheet { return "添加" }
        return "保存"
    }

    private var isValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && URL(string: trimmed)?.scheme != nil
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sheet {
        case .add:
            model.addServer(name: trimmedName, url: trimmedURL, token: trimmedToken)
        case .edit(let server):
            model.updateServer(
                Server(id: server.id, name: trimmedName, url: trimmedURL, token: trimmedToken)
            )
        }
        dismiss()
    }
}

// MARK: - 添加 / 编辑客户端（直接写服务端白名单；编辑时 ID 不可改，改 ID = 删旧加新）

private struct ClientEditView: View {
    @Environment(\.dismiss) private var dismiss
    let session: LinkSession
    let client: WhitelistClient?

    @State private var clientId = ""
    @State private var token = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(client == nil ? "新增客户端" : "编辑客户端") {
                    TextField("客户端 ID（云电脑唯一标识）", text: $clientId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(client != nil)
                    HStack {
                        TextField("Token（该客户端专属）", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Button("随机生成") {
                            token = Self.randomToken()
                        }
                    }
                }
                Section {
                    Text("保存后需在云电脑的 client 配置相同 ID 与 token（.env 的 LINK_CLIENT_ID / LINK_TOKEN，或 --id / --token 参数），配置后重启 client 生效。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(client == nil ? "添加" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || busy)
            }
            .padding(16)
        }
        .frame(width: 500, height: 300)
        .onAppear {
            if let client {
                clientId = client.clientId
                token = client.token
            }
        }
    }

    private var isValid: Bool {
        !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        errorMessage = nil
        let completion: (String?) -> Void = { error in
            busy = false
            if let error { errorMessage = error } else { dismiss() }
        }
        if client != nil {
            session.updateClient(clientId: id, token: newToken, completion: completion)
        } else {
            session.addClient(clientId: id, token: newToken, completion: completion)
        }
    }

    // 与服务端建议一致：openssl rand -hex 16
    private static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }
}

// MARK: - 终端：输出区 + 输入栏（对应选中的服务端及其目标客户端）

struct TerminalView: View {
    @Environment(AppModel.self) private var model
    let session: LinkSession
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            outputView
            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.serverSheet = .edit(session.server)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("编辑服务器")

                Button {
                    session.clearOutput()
                } label: {
                    Image(systemName: "trash")
                }
                .help("清空输出（/clear）")

                Button {
                    session.disconnect()
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                }
                .help("断开连接")
            }
        }
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.lines) { line in
                        Text(line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.lines.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: session.lines.last?.id) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: session.currentTarget) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("\(session.server.displayName) · \(session.currentTargetDisplay)>")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TextField("输入命令（/help 查看帮助）", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .focused($inputFocused)
                .onSubmit(submit)
            Button("发送", action: submit)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let text = input
        input = ""
        session.submit(text)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = session.lines.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func color(for kind: OutputKind) -> Color {
        switch kind {
        case .stdout: .primary
        case .stderr: .red
        case .system: .secondary
        case .command: .accentColor
        case .separator: Color.secondary.opacity(0.4)
        }
    }
}
