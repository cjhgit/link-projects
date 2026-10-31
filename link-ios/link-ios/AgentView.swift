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
    @State private var agentKind: AgentKind = .claude // 新建会话使用的 CLI，默认 Claude Code
    @State private var loading = false
    @State private var sending = false
    @State private var confirmDelete = false
    @State private var deleteCandidate: AgentSessionInfo?
    // 列表范围：mine = 本软件发起或继续过对话的会话（默认）；history = Claude Code 官方记录里的历史对话（回复不改变此列表）
    @State private var scope: AgentListScope = .mine
    @State private var copiedId = false // session id 复制成功后的短暂反馈
    @State private var resumeSheet = false // 按 Session ID 继续对话
    @State private var resumeId = ""
    @State private var resumeError: String?
    @State private var resuming = false

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
            .sheet(isPresented: $resumeSheet) {
                if let current = self.targetId { resumeSheetView(current) }
            }
            // 切换「会话 / Claude 历史」：换一份列表并清空选中态
            .onChange(of: scope) { _, _ in
                selectedId = nil
                creating = false
                if let current = self.targetId { refresh(current) }
            }
            // 列表只带摘要；选中会话后拉取完整消息（claude 会话由 client 实时解析官方 jsonl）
            .onChange(of: selectedId) { _, _ in
                if let current = self.targetId, selectedId != nil { loadDetail(current) }
            }
        } else {
            ContentUnavailableView("请选择在线云电脑", systemImage: "desktopcomputer", description: Text("Agent 仅运行在在线客户端。"))
        }
    }

    private func header(_ targetId: String) -> some View {
        HStack {
            if selected != nil || creating {
                Button {
                    selectedId = nil
                    creating = false
                    prompt = ""
                } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("返回列表")
            }
            Text(selected?.title ?? (creating ? "新建会话" : scopeTitle))
                .font(.headline).lineLimit(1)
            Spacer()
            if creating {
                Button("取消") { creating = false; prompt = "" }
            }
            Menu {
                Button {
                    // 新建属于「会话」页；从 Claude 历史页点 + 自动切回
                    scope = .mine
                    selectedId = nil
                    creating = true
                    prompt = ""
                    cwd = ""
                } label: { Label("新建会话", systemImage: "plus") }
                Button {
                    resumeId = ""
                    resumeError = nil
                    resumeSheet = true
                } label: { Label("按 Session ID 继续…", systemImage: "arrow.uturn.backward.circle") }
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("新建或继续会话")
            Button("刷新") { refresh(targetId) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(loading)
                .accessibilityLabel("刷新会话")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // 会话 ID：点击复制到剪贴板（可粘贴到任意一端「按 Session ID 继续」恢复对话）
    private func sessionIdRow(_ item: AgentSessionInfo) -> some View {
        HStack(spacing: 4) {
            Image(systemName: copiedId ? "checkmark" : "doc.on.doc").font(.caption2)
            Text(copiedId ? "已复制" : item.sessionId)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = item.sessionId
            copiedId = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedId = false }
        }
        .help("点击复制 Session ID")
    }

    // 按 Session ID 继续：粘贴任意一端复制的会话 ID，云电脑上仍存在即可接着聊
    private func resumeSheetView(_ targetId: String) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session ID", text: $resumeId)
                        .font(.system(.callout, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("粘贴会话 ID（可从任一端的会话详情点击复制），云电脑上仍存在的会话即可继续对话。")
                }
                if let resumeError {
                    Section { Text(resumeError).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("按 Session ID 继续")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { resumeSheet = false }.disabled(resuming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if resuming {
                        ProgressView()
                    } else {
                        Button("继续") { resumeById(targetId) }
                            .disabled(resumeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(resuming)
    }

    private func resumeById(_ targetId: String) {
        // 官方会话 ID 为小写 UUID，粘贴大写也能命中
        let id = resumeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        resuming = true
        resumeError = nil
        session.agentStatus(targetId: targetId, sessionId: id) { result in
            resuming = false
            if let item = result.first {
                resumeSheet = false
                scope = .mine
                applyUpdates([item])
                selectedId = item.id
                creating = false
            } else {
                resumeError = "云电脑上未找到该会话（可能已被清理或 ID 有误）"
            }
        }
    }

    // Claude 历史列表的状态只由官方 jsonl 决定（存在即完整），不显示本软件的运行状态
    private func effectiveState(_ item: AgentSessionInfo) -> AgentSessionState {
        scope == .mine ? item.state : .completed
    }

    // header 标题：按当前 tab 显示
    private var scopeTitle: String {
        switch scope {
        case .mine: "会话"
        case .claudeHistory: "Claude 历史"
        case .codexHistory: "Codex 历史"
        case .cursorHistory: "Cursor 历史"
        case .piHistory: "Pi 历史"
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            Picker("范围", selection: $scope) {
                Text("会话").tag(AgentListScope.mine)
                Text("Claude").tag(AgentListScope.claudeHistory)
                Text("Codex").tag(AgentListScope.codexHistory)
                Text("Cursor").tag(AgentListScope.cursorHistory)
                Text("Pi").tag(AgentListScope.piHistory)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            List(sessions) { item in
                Button {
                    selectedId = item.id
                    creating = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: effectiveState(item) == .running ? "clock" : effectiveState(item) == .completed ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(effectiveState(item) == .running ? .orange : effectiveState(item) == .completed ? .green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).foregroundStyle(.primary).lineLimit(1)
                            Text(item.cwd ?? "~/.link-projects/workspace").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        // 「会话」页里标记从 Claude 历史导入的记录
                        if item.origin == .external && scope == .mine {
                            Text("外部").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).background(Color.cyan.opacity(0.18)).clipShape(Capsule())
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) {
                        deleteCandidate = item
                        confirmDelete = true
                    }
                    // History 里的会话由 Claude Code 管理，不能在这里删除
                    .disabled(item.state == .running || scope != .mine)
                }
            }
            .overlay {
                if sessions.isEmpty && !loading {
                    ContentUnavailableView(
                        scope == .mine ? "暂无会话" : "暂无\(scope == .claudeHistory ? " Claude" : scope == .codexHistory ? " Codex" : scope == .cursorHistory ? " Cursor" : " Pi") 历史对话",
                        systemImage: scope == .mine ? "bubble.left.and.bubble.right" : "clock.arrow.circlepath",
                        description: Text(scope == .mine ? "点击右上角 + 在云电脑创建 Claude Code 会话。" : "云电脑的官方会话文件里暂无可恢复的会话")
                    )
                }
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
                    sessionIdRow(selected)
                    if isResponding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(selected.agent.displayName) 正在响应…")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = selected.error { Text(error).foregroundStyle(.red) }
                    ForEach(selected.messages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role == "user" ? "你" : selected.agent.displayName).font(.caption).foregroundStyle(.secondary)
                            Text(message.content).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(message.role == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let streaming = selected.streaming, !streaming.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selected.agent.displayName).font(.caption).foregroundStyle(.secondary)
                            Text(streaming).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if selected.state == .running && selected.messages.isEmpty {
                        // 无增量输出时的占位（官方 jsonl 未落盘、CLI 尚未产出文本）
                        Text("正在处理…").font(.callout).foregroundStyle(.secondary)
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
                HStack(spacing: 8) {
                    TextField("工作目录（默认 ~/.link-projects/workspace）", text: $cwd).textFieldStyle(.roundedBorder)
                    Picker("CLI", selection: $agentKind) {
                        Text("Claude Code").tag(AgentKind.claude)
                        Text("Codex").tag(AgentKind.codex)
                        Text("Cursor").tag(AgentKind.cursor)
                        Text("Pi").tag(AgentKind.pi)
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                        .help("新建会话使用的命令行工具；Claude Code 为默认。")
                }
            }
            HStack(alignment: .bottom) {
                TextField(creating ? "告诉 \(agentKind.displayName) 要做什么" : "继续这个会话", text: $prompt, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                Button { run(targetId) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding)
            }
            if isResponding {
                Text("云电脑仍在执行，可稍后刷新查看结果。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(10)
    }

    // 项目页发起的「新建会话」：切回「会话」页并预填工作目录
    private func prepareNewSession() {
        guard let initialCwd, !initialCwd.isEmpty else { return }
        scope = .mine
        selectedId = nil
        creating = true
        prompt = ""
        cwd = initialCwd
    }

    private func refresh(_ targetId: String) {
        loading = true
        session.listAgentSessions(targetId: targetId, scope: scope) { result in
            loading = false; sessions = result
            if selectedId != nil, !result.contains(where: { $0.id == selectedId }) { selectedId = nil; creating = false }
            else if selectedId != nil { loadDetail(targetId) } // 摘要覆盖了消息，重新拉详情
        }
    }

    private func loadDetail(_ targetId: String) {
        guard let id = selectedId else { return }
        session.agentStatus(targetId: targetId, sessionId: id) { result in
            for item in result { applyUpdates([item]) }
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
        session.runAgent(targetId: targetId, prompt: text, sessionId: selectedId, cwd: creating ? cwd : nil, agent: creating ? agentKind : nil) { result in
            sending = false; prompt = ""
            if let item = result.first {
                if let i = sessions.firstIndex(where: { $0.id == item.id }) { sessions[i] = item } else { sessions.insert(item, at: 0) }
                selectedId = item.id; creating = false
            }
        }
    }
}
