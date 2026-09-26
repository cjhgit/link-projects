import SwiftUI

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
        .sheet(item: $model.serverSheet) { sheet in
            ServerSheetView(sheet: sheet)
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

// MARK: - 当前服务端的在线客户端（选中即 /use，不同服务端客户端各自独立）

private struct ClientSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.selectedSession {
            List(selection: Binding(
                get: { session.currentTarget },
                set: { id in
                    if let id, id != session.currentTarget {
                        session.currentTarget = id
                        session.append("[已选择 \(id)]", .system)
                    }
                }
            )) {
                ForEach(session.onlineClients) { client in
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(client.clientId)
                        if client.clientId == session.currentTarget {
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(client.clientId)
                }
            }
            .overlay {
                if session.onlineClients.isEmpty {
                    ContentUnavailableView(
                        session.state == .connected ? "无在线客户端" : "未连接",
                        systemImage: "desktopcomputer.and.iphone",
                        description: Text(session.state == .connected ? "等待云电脑接入…" : "请先连接该服务器")
                    )
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("在线客户端（\(session.onlineClients.count)）")
                        .font(.headline)
                    Spacer()
                    Button {
                        if session.state == .connected {
                            session.append("/list", .command)
                            session.submitList()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新在线列表")
                    .disabled(session.state != .connected)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        } else {
            ContentUnavailableView(
                "未选择服务器",
                systemImage: "server.rack",
                description: Text(model.servers.isEmpty ? "请先添加服务器" : "请在左侧选择服务器")
            )
        }
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
                TerminalView(session: session)
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

// MARK: - 终端：输出区 + 输入栏（对应选中的服务端及其目标客户端）

private struct TerminalView: View {
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
            Text("\(session.server.displayName) · \(session.currentTarget ?? "(未选择)")>")
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
