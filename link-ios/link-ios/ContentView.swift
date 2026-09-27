import SwiftUI
import UIKit

// MARK: - 根视图：服务器列表 → 客户端列表 → 工作区（终端 / 文件），push 导航适配手机

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ServerListView()
                .navigationDestination(for: UUID.self) { serverId in
                    ClientListView(serverId: serverId)
                }
        }
        .sheet(item: $model.serverSheet) { sheet in
            ServerSheetView(sheet: sheet)
        }
        .sheet(item: $model.clientEditSheet) { sheet in
            ClientEditView(session: sheet.session, client: sheet.client)
        }
    }
}

// MARK: - 服务器列表（多服务端：push 进哪个，客户端与终端就归属哪个）

private struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: Server?

    var body: some View {
        List {
            ForEach(model.servers) { server in
                NavigationLink(value: server.id) {
                    serverRow(server)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if let session = model.sessions[server.id] {
                        if session.state == .disconnected {
                            Button("连接") { session.connect() }
                                .tint(.green)
                        } else {
                            Button("断开") { session.disconnect() }
                                .tint(.red)
                        }
                    }
                    Button("编辑") { model.serverSheet = .edit(server) }
                        .tint(.blue)
                    Button("删除", role: .destructive) { confirmDelete = server }
                }
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
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.serverSheet = .add
                } label: {
                    Image(systemName: "plus")
                }
            }
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
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(model.state(of: server)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .lineLimit(1)
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let version = model.sessions[server.id]?.serverVersion {
                Text("v\(version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let session = model.sessions[server.id], session.state == .connected {
                Text("\(session.onlineClients.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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

// MARK: - 当前服务端的客户端列表（白名单全体，在线只是状态；点击选择目标并进入工作区）

private struct ClientListView: View {
    @Environment(AppModel.self) private var model
    let serverId: UUID
    // 删除确认携带发起时的会话，避免弹窗期间切换服务端后误删到别的服务端
    @State private var confirmDelete: (session: LinkSession, client: WhitelistClient)?
    @State private var workspaceClientId: String?

    var body: some View {
        if let session = model.sessions[serverId] {
            List {
                connectionSection(session)
                Section {
                    serverHostRow(session)
                    ForEach(session.clientRows) { row in
                        clientRow(row, session: session)
                    }
                } footer: {
                    if session.state != .connected, !session.clientRows.isEmpty {
                        Text("未连接，显示上次同步的白名单")
                    }
                }
            }
            .navigationTitle(session.server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $workspaceClientId) { clientId in
                WorkspaceView(serverId: serverId, clientId: clientId)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.clientEditSheet = ClientEditSheet(session: session, client: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(session.state != .connected)
                    Button {
                        session.append("/list", .command)
                        session.submitList()
                        session.refreshWhitelist { error in
                            if let error {
                                session.append("[刷新白名单失败] \(error)", .system, to: "")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(session.state != .connected)
                }
            }
            .onAppear { session.autoConnectIfNeeded() }
            .confirmationDialog(
                "删除客户端",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                titleVisibility: .automatic,
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
            ContentUnavailableView("服务器不存在", systemImage: "server.rack")
        }
    }

    // 未连接时置顶的连接状态区（可手动连接；失败原因显示在此）
    @ViewBuilder
    private func connectionSection(_ session: LinkSession) -> some View {
        if session.state != .connected {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        switch session.state {
                        case .connecting:
                            ProgressView()
                            Text("连接中…")
                                .foregroundStyle(.secondary)
                        case .disconnected:
                            Text("未连接")
                                .foregroundStyle(.secondary)
                        case .connected:
                            EmptyView()
                        }
                        Spacer()
                        if session.state == .disconnected {
                            Button("连接") { session.connect() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                    // 最近一条系统提示（连接失败原因）显示在这里
                    if let lastError = (session.outputs[""] ?? []).last(where: { $0.kind == .system }) {
                        Text(lastError.text)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // 固定首行：服务器主机（@server 保留目标），点击进入工作区，「文件」页签浏览 server 本机文件
    private func serverHostRow(_ session: LinkSession) -> some View {
        Button {
            selectServerHost(session)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.state == .connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Image(systemName: "server.rack")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("服务器主机")
                    .lineLimit(1)
                if let version = session.serverVersion {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.currentTarget == LinkSession.serverTargetId {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectServerHost(_ session: LinkSession) {
        if session.currentTarget != LinkSession.serverTargetId {
            session.currentTarget = LinkSession.serverTargetId
            session.append("[已选择 服务器主机，终端与「文件」页签直接操作 server 本机]", .system)
        }
        workspaceClientId = LinkSession.serverTargetId
    }

    private func clientRow(_ row: ClientRow, session: LinkSession) -> some View {
        Button {
            select(row, session: session)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.online ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(row.clientId)
                    .lineLimit(1)
                if let version = row.version {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.clientId == session.currentTarget {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) {
                confirmDelete = (session, WhitelistClient(clientId: row.clientId, token: row.token ?? "", online: row.online))
            }
            .disabled(row.token == nil || session.state != .connected)
            Button("编辑") {
                model.clientEditSheet = ClientEditSheet(
                    session: session,
                    client: WhitelistClient(clientId: row.clientId, token: row.token ?? "", online: row.online)
                )
            }
            .tint(.blue)
            .disabled(row.token == nil || session.state != .connected)
        }
        .contextMenu {
            Button {
                copy(row.clientId)
            } label: {
                Label("拷贝 ID", systemImage: "doc.on.doc")
            }
            // token 为 nil 的回退行（旧版 server）没有白名单数据，不提供管理项
            if let token = row.token, !token.isEmpty {
                Button {
                    copy(token)
                } label: {
                    Label("拷贝 Token", systemImage: "key")
                }
                Button {
                    copy("LINK_SERVER=\(session.server.url)\nLINK_CLIENT_ID=\(row.clientId)\nLINK_TOKEN=\(token)")
                } label: {
                    Label("拷贝接入配置（.env）", systemImage: "doc.on.clipboard")
                }
                Divider()
                Button {
                    model.clientEditSheet = ClientEditSheet(
                        session: session,
                        client: WhitelistClient(clientId: row.clientId, token: token, online: row.online)
                    )
                } label: {
                    Label("编辑…", systemImage: "square.and.pencil")
                }
                .disabled(session.state != .connected)
                Button(role: .destructive) {
                    confirmDelete = (session, WhitelistClient(clientId: row.clientId, token: token, online: row.online))
                } label: {
                    Label("删除…", systemImage: "trash")
                }
                .disabled(session.state != .connected)
            }
        }
    }

    private func select(_ row: ClientRow, session: LinkSession) {
        if row.clientId != session.currentTarget {
            session.currentTarget = row.clientId
            let online = session.onlineClients.contains { $0.clientId == row.clientId }
            session.append("[已选择 \(row.clientId)\(online ? "" : "（离线）")]", .system)
        }
        workspaceClientId = row.clientId
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
        UIPasteboard.general.string = text
    }
}

// MARK: - 工作区：选中客户端后的操作页（项目 / 终端 / 文件 / Agent 切换）。
// 项目页发起的跳转（打开目录 / 新建会话）通过 filesDir / agentCwd 传给对应页面

private struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    let serverId: UUID
    let clientId: String
    @State private var tab: DetailTab = .projects
    @State private var filesDir: String? // 「文件」页要定位的目录（项目页发起）
    @State private var agentCwd: String? // 「Agent」页新建会话预填的工作目录（项目页发起）

    var body: some View {
        if let session = model.sessions[serverId] {
            VStack(spacing: 0) {
                Picker("工作模式", selection: $tab) {
                    Text("项目").tag(DetailTab.projects)
                    Text("终端").tag(DetailTab.terminal)
                    Text("文件").tag(DetailTab.files)
                    Text("Agent").tag(DetailTab.agent)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                switch tab {
                case .projects:
                    ProjectView(
                        session: session,
                        onOpenFiles: { dir in
                            filesDir = dir
                            tab = .files
                        },
                        onNewAgent: { cwd in
                            agentCwd = cwd
                            tab = .agent
                        }
                    )
                case .terminal:
                    TerminalView(session: session)
                case .files:
                    FileBrowserView(session: session, path: filesDir ?? "~", resetsOnTargetChange: true)
                case .agent:
                    AgentView(session: session, initialCwd: agentCwd)
                }
            }
            .navigationTitle(session.currentTargetDisplay)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 进入工作区 = 设为当前目标（对齐 /use）
                if session.currentTarget != clientId {
                    session.currentTarget = clientId
                }
            }
            // 切换目标客户端后，项目页留下的定位目录 / 工作目录属于另一台机器，一并清掉
            .onChange(of: session.currentTarget) { _, _ in
                filesDir = nil
                agentCwd = nil
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            session.append("/list", .command)
                            session.submitList()
                        } label: {
                            Label("刷新在线列表", systemImage: "arrow.clockwise")
                        }
                        .disabled(session.state != .connected)
                        Button(role: .destructive) {
                            session.disconnect()
                        } label: {
                            Label("断开连接", systemImage: "antenna.radiowaves.left.and.right.slash")
                        }
                        .disabled(session.state == .disconnected)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } else {
            ContentUnavailableView("服务器不存在", systemImage: "server.rack")
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
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可选，默认用地址）", text: $name)
                    TextField("地址（ws://host:port）", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.callout, design: .monospaced))
                        .keyboardType(.URL)
                    TextField("Token（服务端 CONTROLLER_TOKEN）", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.callout, design: .monospaced))
                } footer: {
                    Text("支持 ws:// 与 wss://，可在服务端配置 TLS 后用 wss:// 加密连接")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveTitle, action: save)
                        .disabled(!isValid)
                        .bold()
                }
            }
        }
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
        NavigationStack {
            Form {
                Section(client == nil ? "新增客户端" : "编辑客户端") {
                    TextField("客户端 ID（云电脑唯一标识）", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(client != nil)
                    HStack {
                        TextField("Token（该客户端专属）", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.callout, design: .monospaced))
                        Button {
                            token = Self.randomToken()
                        } label: {
                            Label("随机生成", systemImage: "dice")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Section {
                    Text("保存后需在云电脑的 client 配置相同 ID 与 token（.env 的 LINK_CLIENT_ID / LINK_TOKEN，或 --id / --token 参数），配置后重启 client 生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(client == nil ? "新增客户端" : "编辑客户端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(client == nil ? "添加" : "保存", action: save)
                            .disabled(!isValid)
                            .bold()
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
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
            if error == nil { dismiss() } else { errorMessage = error }
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
    let session: LinkSession
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            outputView
            Divider()
            inputBar
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
            // 下滑输出区可顺手收起键盘
            .scrollDismissesKeyboard(.interactively)
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
            TextField(
                "\(session.currentTargetDisplay) › 输入命令，/help 查看帮助",
                text: $input
            )
            .font(.system(.callout, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .focused($inputFocused)
            .onSubmit(submit)
            // 原键盘工具栏在 iOS 27 会浮起遮挡输入框，改为输入栏内按钮
            if inputFocused {
                Button {
                    inputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .foregroundStyle(.secondary)
            }
            Button {
                session.clearOutput()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(session.lines.isEmpty)
            Button {
                submit()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.default, value: inputFocused)
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
