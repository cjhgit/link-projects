import SwiftUI
import AppKit

// Agent（Claude Code / Codex CLI）的轻量会话前端：这里只保存当前界面状态，记录与任务状态都由云电脑 client 保存。
struct AgentView: View {
    let session: LinkSession
    var initialCwd: String? = nil // 项目页「新建会话」跳转时预填的工作目录
    @State private var sessions: [AgentSessionInfo] = []
    @State private var selectedId: String?
    @State private var prompt = ""
    @State private var cwd = ""
    @State private var agentKind: AgentKind = .claude // 新建会话使用的 CLI，默认 Claude Code
    @State private var loading = false
    @State private var copiedId = false // session id 复制成功后的短暂反馈
    @State private var sending = false
    @State private var confirmDelete = false
    // 列表范围：mine = 本软件发起或继续过对话的会话（默认）；history = Claude Code 官方记录里的外部会话
    @State private var scope: AgentListScope = .mine

    private var targetId: String? {
        guard let id = session.currentTarget, id != LinkSession.serverTargetId,
              session.onlineClients.contains(where: { $0.clientId == id }) else { return nil }
        return id
    }
    private var selected: AgentSessionInfo? { sessions.first { $0.id == selectedId } }
    private var isResponding: Bool { sending || selected?.state == .running }

    var body: some View {
        if let targetId {
            HSplitView {
                VStack(spacing: 0) {
                    Picker("范围", selection: $scope) {
                        Text("会话").tag(AgentListScope.mine)
                        Text("Claude 历史").tag(AgentListScope.claudeHistory)
                        Text("Codex 历史").tag(AgentListScope.codexHistory)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .help("「会话」= 本软件发起或继续过对话的会话；「Claude 历史 / Codex 历史」= 云电脑上 CLI 直接发起的对话，完全由官方会话文件决定，回复不会使它离开这里")
                    Divider()
                    List(selection: $selectedId) {
                        ForEach(sessions) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.title).lineLimit(1)
                                    Spacer()
                                    // 「会话」页里标记从 Claude 历史导入的记录
                                    if item.origin == .external && scope == .mine {
                                        Text("外部").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).background(Color.cyan.opacity(0.18)).clipShape(Capsule())
                                            .help("在云电脑上由 Claude Code 直接发起、经本软件继续过对话的会话")
                                    }
                                    Text(item.agent == .codex ? "Codex" : "Claude").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                                    // Claude 历史的状态只由官方 jsonl 决定（存在即完整），不显示本软件的运行状态
                                    stateIcon(scope == .mine ? item.state : .completed)
                                }
                                Text(item.cwd ?? "默认目录").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.tag(item.id)
                        }
                    }
                    .overlay {
                        if sessions.isEmpty && !loading {
                            ContentUnavailableView(scope == .mine ? "还没有会话" : historyEmptyTitle, systemImage: scope == .mine ? "sparkles" : "clock.arrow.circlepath", description: Text(scope == .mine ? "在下方输入任务，或从项目页发起新会话" : "云电脑的 \(historyEmptyTitle)里暂无可恢复的会话"))
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 250)
                VStack(spacing: 0) {
                    conversation
                    Divider()
                    composer(targetId: targetId)
                }
            }
            .persistedSplitView("agent-session-columns")
            .toolbar {
                Button { scope = .mine; selectedId = nil; prompt = "" } label: { Image(systemName: "square.and.pencil") }.help("新建会话")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help(scope == .mine ? "删除 Link 会话记录（不会删除 CLI 自己的会话）" : "历史会话由 CLI 官方文件管理，不能在这里删除")
                    .disabled(selected == nil || selected?.state == .running || scope != .mine)
                Button { refresh(targetId) } label: { Image(systemName: "arrow.clockwise") }.help("刷新会话状态和输出").disabled(loading)
            }
            .confirmationDialog("删除 Link 会话记录", isPresented: $confirmDelete) {
                Button("删除（不会删除 CLI 自己的会话）", role: .destructive) { deleteSelected(targetId) }
                Button("取消", role: .cancel) {}
            } message: { Text("只会删除本应用在云电脑保存的会话记录，Claude Code / Codex 的原生会话不会受影响。") }
            .onAppear {
                session.observeAgentUpdates(targetId: targetId) { applyUpdates($0) }
                refresh(targetId)
                prepareNewSession()
            }
            .onDisappear { session.stopObservingAgentUpdates(targetId: targetId) }
            .onChange(of: session.currentTarget) { _, _ in if let current = self.targetId { refresh(current) } }
            // 切换会话 / Claude 历史：换一份列表，选中态清空
            .onChange(of: scope) { _, _ in
                selectedId = nil
                if let current = self.targetId { refresh(current) }
            }
            // 列表只带摘要；选中会话后拉取完整消息（claude 会话由 client 实时解析官方 jsonl）
            .onChange(of: selectedId) { _, _ in if let current = self.targetId { loadDetail(current) } }
            // 项目页再次发起「新建会话」时更新预填目录
            .onChange(of: initialCwd) { _, _ in prepareNewSession() }
        } else {
            ContentUnavailableView("请选择在线云电脑", systemImage: "desktopcomputer", description: Text("Agent 仅运行在已在线的客户端；服务器主机不提供此功能。"))
        }
    }

    // 会话 ID：点击复制到剪贴板（claude 会话即 CLI 的 --resume ID）
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.sessionId, forType: .string)
            copiedId = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedId = false }
        }
        .help("点击复制 Session ID")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        HStack { Text(selected.title).font(.headline); Spacer(); stateLabel(selected.state) }
                        sessionIdRow(selected)
                        if isResponding {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(selected.agent.displayName) 正在响应…")
                            }
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = selected.error { Text(error).foregroundStyle(.red).font(.callout) }
                        ForEach(selected.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role == "user" ? "你" : selected.agent.displayName).font(.caption).foregroundStyle(.secondary)
                                Text(message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10).background(message.role == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8)).id(message.id)
                        }
                        if let streaming = selected.streaming, !streaming.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selected.agent.displayName).font(.caption).foregroundStyle(.secondary)
                                Text(streaming).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10).background(Color.secondary.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8)).id("streaming-bubble")
                        } else if selected.state == .running && selected.messages.isEmpty {
                            // 无增量输出时也给出“正在处理”的占位（官方 jsonl 未落盘、CLI 尚未产出文本）
                            Text("正在处理…").font(.callout).foregroundStyle(.secondary).padding(10)
                        }
                    } else if scope != .mine {
                        ContentUnavailableView("选择一个历史会话", systemImage: "clock.arrow.circlepath", description: Text("消息读取自云电脑上 Claude Code 的官方会话文件；输入内容即可在这个会话里继续对话。"))
                    } else {
                        ContentUnavailableView("新建 Agent 会话", systemImage: "sparkles", description: Text("选择 Claude Code 或 Codex，输入任务后会在所选云电脑运行；可随时刷新查看完成状态。"))
                    }
                }.padding(14)
            }
            .onChange(of: selected?.messages.count) { _, _ in if let last = selected?.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: selected?.streaming) { _, _ in proxy.scrollTo("streaming-bubble", anchor: .bottom) }
        }
    }

    private func composer(targetId: String) -> some View {
        VStack(spacing: 7) {
            // 新建会话的工作目录 / CLI 选择只在「会话」页提供；Claude 历史页必须先选中一个会话
            if selectedId == nil && scope == .mine {
                HStack(spacing: 8) {
                    TextField("工作目录（可选）", text: $cwd).textFieldStyle(.roundedBorder)
                    Picker("CLI", selection: $agentKind) {
                        Text("Claude Code").tag(AgentKind.claude)
                        Text("Codex").tag(AgentKind.codex)
                    }.pickerStyle(.menu).labelsHidden().fixedSize().help("新建会话使用的命令行工具；Claude Code 为默认。")
                }
            }
            HStack(alignment: .bottom) {
                TextField(selectedId == nil ? (scope == .mine ? "告诉 \(agentKind.displayName) 要什么" : "先在左侧选择一个会话") : "继续这个会话", text: $prompt, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder)
                    .onSubmit { run(targetId) }
                Button("发送") { run(targetId) }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding || (scope != .mine && selectedId == nil))
            }
            if isResponding { Text("任务正在云电脑执行；网络断开后仍可稍后刷新查看结果。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(10)
    }

    // 项目页发起的「新建会话」：切回「会话」页并预填工作目录
    private func prepareNewSession() {
        guard let initialCwd, !initialCwd.isEmpty else { return }
        scope = .mine
        selectedId = nil
        prompt = ""
        cwd = initialCwd
    }

    private var historyEmptyTitle: String { scope == .codexHistory ? "Codex 历史对话" : "Claude 历史对话" }

    private func refresh(_ targetId: String) {
        loading = true
        session.listAgentSessions(targetId: targetId, scope: scope) { result in
            loading = false; sessions = result
            if selectedId != nil, !result.contains(where: { $0.id == selectedId }) { selectedId = nil }
            else if selectedId != nil { loadDetail(targetId) } // 摘要覆盖了消息，重新拉详情
        }
    }
    private func loadDetail(_ targetId: String) {
        guard let id = selectedId else { return }
        session.agentStatus(targetId: targetId, sessionId: id) { result in for item in result { upsert(item) } }
    }
    private func applyUpdates(_ updates: [AgentSessionInfo]) {
        for item in updates { upsert(item) }
    }
    private func deleteSelected(_ targetId: String) {
        guard let item = selected else { return }
        session.deleteAgentSession(targetId: targetId, sessionId: item.id) { _ in
            sessions.removeAll { $0.id == item.id }
            selectedId = nil
        }
    }
    private func run(_ targetId: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        sending = true
        // agent 只在新建时传；继续会话由 client 按会话记录的类型调用对应 CLI
        session.runAgent(targetId: targetId, prompt: text, sessionId: selectedId, cwd: selectedId == nil ? cwd : nil, agent: selectedId == nil ? agentKind : nil) { result in
            sending = false; prompt = ""; if let item = result.first { upsert(item); selectedId = item.id }
        }
    }
    private func upsert(_ item: AgentSessionInfo) { if let i = sessions.firstIndex(where: { $0.id == item.id }) { sessions[i] = item } else { sessions.insert(item, at: 0) } }
    @ViewBuilder private func stateIcon(_ state: AgentSessionState) -> some View { Image(systemName: state == .running ? "clock" : state == .completed ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(state == .running ? .orange : state == .completed ? .green : .red) }
    @ViewBuilder private func stateLabel(_ state: AgentSessionState) -> some View { Text(state == .running ? "执行中" : state == .completed ? "已完成" : "失败").font(.caption).foregroundStyle(.secondary) }
}
