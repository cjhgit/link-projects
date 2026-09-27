import SwiftUI

// 会话记录由云电脑 client 持久化；默认先展示会话列表，+ 才进入新建流程。
struct AgentView: View {
    let session: LinkSession
    var initialCwd: String? = nil // 项目页「新建会话」跳转时预填的工作目录
    @State private var sessions: [AgentSessionInfo] = []
    @State private var selectedId: String?
    @State private var creating = false
    @State private var prompt = ""
    @State private var cwd = ""
    @State private var loading = false
    @State private var sending = false
    @State private var confirmDelete = false
    @State private var deleteCandidate: AgentSessionInfo?

    private var targetId: String? {
        guard let id = session.currentTarget, id != LinkSession.serverTargetId,
              session.onlineClients.contains(where: { $0.clientId == id }) else { return nil }
        return id
    }
    private var selected: AgentSessionInfo? { sessions.first { $0.id == selectedId } }
    private var isResponding: Bool { sending || selected?.state == .running }

    var body: some View {
        if let targetId {
            VStack(spacing: 0) {
                header(targetId)
                Divider()
                if selected != nil || creating {
                    conversation
                    Divider()
                    composer(targetId)
                } else {
                    sessionList
                }
            }
            .onAppear { refresh(targetId) }
            .onAppear { session.observeAgentUpdates(targetId: targetId) { applyUpdates($0) } }
            .onAppear { prepareNewSession() }
            .onDisappear { session.stopObservingAgentUpdates(targetId: targetId) }
            // 项目页再次发起「新建会话」时更新预填目录
            .onChange(of: initialCwd) { _, _ in prepareNewSession() }
            .confirmationDialog("删除 Link 会话记录", isPresented: $confirmDelete) {
                Button("删除（不会删除 Claude 会话）", role: .destructive) {
                    if let item = deleteCandidate { deleteSelected(targetId, item: item) }
                }
                Button("取消", role: .cancel) { deleteCandidate = nil }
            } message: { Text("仅删除云电脑保存的 Link 会话记录。") }
            .onChange(of: session.currentTarget) { _, _ in
                if let current = self.targetId { refresh(current) }
            }
        } else {
            ContentUnavailableView("请选择在线云电脑", systemImage: "desktopcomputer", description: Text("Agent 仅运行在在线客户端。"))
        }
    }

    private func header(_ targetId: String) -> some View {
        HStack {
            Text(selected?.title ?? (creating ? "新建会话" : "会话"))
                .font(.headline).lineLimit(1)
            Spacer()
            if creating {
                Button("取消") { creating = false; prompt = "" }
            }
            Button {
                selectedId = nil
                creating = true
                prompt = ""
                cwd = ""
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("新建会话")
            Button("刷新") { refresh(targetId) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(loading)
                .accessibilityLabel("刷新会话")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var sessionList: some View {
        List(sessions) { item in
            Button {
                selectedId = item.id
                creating = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.state == .running ? "clock" : item.state == .completed ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(item.state == .running ? .orange : item.state == .completed ? .green : .red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).foregroundStyle(.primary).lineLimit(1)
                        Text(item.cwd ?? "~/.link-projects/workspace").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("删除", role: .destructive) {
                    deleteCandidate = item
                    confirmDelete = true
                }
                .disabled(item.state == .running)
            }
        }
        .overlay {
            if sessions.isEmpty && !loading {
                ContentUnavailableView("暂无会话", systemImage: "bubble.left.and.bubble.right", description: Text("点击右上角 + 在云电脑创建 Claude Code 会话。"))
            }
        }
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let selected {
                    HStack {
                        Text(selected.title).font(.headline)
                        Spacer()
                        Text(selected.state == .running ? "执行中" : selected.state == .completed ? "已完成" : "失败")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if isResponding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Claude Code 正在响应…")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = selected.error { Text(error).foregroundStyle(.red) }
                    ForEach(selected.messages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role == "user" ? "你" : "Claude Code").font(.caption).foregroundStyle(.secondary)
                            Text(message.content).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(message.role == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    ContentUnavailableView("新建 Claude Code 会话", systemImage: "sparkles", description: Text("默认工作目录为 ~/.link-projects/workspace。"))
                }
            }.padding(12)
        }
    }

    private func composer(_ targetId: String) -> some View {
        VStack(spacing: 6) {
            if creating {
                TextField("工作目录（默认 ~/.link-projects/workspace）", text: $cwd).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .bottom) {
                TextField(creating ? "告诉 Claude Code 要做什么" : "继续这个会话", text: $prompt, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                Button { run(targetId) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding)
            }
            if isResponding {
                Text("云电脑仍在执行，可稍后刷新查看结果。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(10)
    }

    // 项目页发起的「新建会话」：切到新建状态并预填工作目录
    private func prepareNewSession() {
        guard let initialCwd, !initialCwd.isEmpty else { return }
        selectedId = nil
        creating = true
        prompt = ""
        cwd = initialCwd
    }

    private func refresh(_ targetId: String) {
        loading = true
        session.listAgentSessions(targetId: targetId) { result in
            loading = false; sessions = result
            if selectedId != nil, !result.contains(where: { $0.id == selectedId }) { selectedId = nil; creating = false }
        }
    }

    private func applyUpdates(_ updates: [AgentSessionInfo]) {
        for item in updates {
            if let i = sessions.firstIndex(where: { $0.id == item.id }) { sessions[i] = item }
            else { sessions.insert(item, at: 0) }
        }
    }

    private func deleteSelected(_ targetId: String, item: AgentSessionInfo) {
        session.deleteAgentSession(targetId: targetId, sessionId: item.id) { _ in
            sessions.removeAll { $0.id == item.id }
            selectedId = nil
            creating = false
            deleteCandidate = nil
        }
    }

    private func run(_ targetId: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        sending = true
        session.runAgent(targetId: targetId, prompt: text, sessionId: selectedId, cwd: creating ? cwd : nil) { result in
            sending = false; prompt = ""
            if let item = result.first {
                if let i = sessions.firstIndex(where: { $0.id == item.id }) { sessions[i] = item } else { sessions.insert(item, at: 0) }
                selectedId = item.id; creating = false
            }
        }
    }
}
