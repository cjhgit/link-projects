import SwiftUI

struct ContentView: View {
    @Environment(LinkSession.self) private var session

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            if session.state == .connected {
                TerminalView()
            } else {
                ConnectView()
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - 在线客户端列表（选中即 /use）

private struct SidebarView: View {
    @Environment(LinkSession.self) private var session

    var body: some View {
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
                    description: Text(session.state == .connected ? "等待云电脑接入…" : "请先连接服务器")
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
    }
}

// MARK: - 连接配置（未连接时显示）

private struct ConnectView: View {
    @Environment(LinkSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            Section("服务器") {
                TextField("地址（ws://host:port）", text: $session.serverURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Token（服务端 CONTROLLER_TOKEN）", text: $session.token)
                    .textFieldStyle(.roundedBorder)
            }
            Section {
                HStack {
                    switch session.state {
                    case .connecting:
                        ProgressView().controlSize(.small)
                        Text("连接中…")
                    case .disconnected:
                        Button("连接") { session.connect() }
                            .controlSize(.large)
                            .disabled(session.serverURL.isEmpty)
                    case .connected:
                        EmptyView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.autoConnectIfNeeded() }
    }
}

// MARK: - 终端：输出区 + 输入栏

private struct TerminalView: View {
    @Environment(LinkSession.self) private var session
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
            Text("\(session.currentTarget ?? "(未选择)")>")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
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
