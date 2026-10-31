import SwiftUI

// 项目管理：项目 = 云电脑上的常用目录，数据由 client 保存在本机（同 Agent 会话）。
// 每个项目提供两个快捷入口：打开目录（跳「文件」页定位）、新建会话（跳「Agent」页预填工作目录）。
struct ProjectView: View {
    let session: LinkSession
    let onOpenFiles: (String) -> Void
    let onNewAgent: (String) -> Void
    var onOpenDetail: ((ProjectInfo) -> Void)? = nil // 打开项目详情（文件 / 终端 / Agent / 命令）

    @State private var projects: [ProjectInfo] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var editSheet: ProjectEditSheet?
    @State private var confirmDelete: ProjectInfo?

    struct ProjectEditSheet: Identifiable {
        let project: ProjectInfo?
        let targetId: String
        let id = UUID()
    }

    private var targetId: String? {
        guard let id = session.currentTarget, id != LinkSession.serverTargetId,
              session.onlineClients.contains(where: { $0.clientId == id }) else { return nil }
        return id
    }

    var body: some View {
        if let targetId {
            VStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                }
                list(targetId)
            }
            .overlay {
                if loading && projects.isEmpty { ProgressView("读取中…") }
            }
            .toolbar {
                Button {
                    editSheet = ProjectEditSheet(project: nil, targetId: targetId)
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加项目（常用目录）")
                Button { refresh(targetId) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新项目列表")
                .disabled(loading)
            }
            .sheet(item: $editSheet, onDismiss: { refresh(targetId) }) { sheet in
                ProjectEditView(session: session, sheet: sheet)
            }
            .confirmationDialog(
                "删除项目",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                presenting: confirmDelete
            ) { project in
                Button("删除“\(project.name)”", role: .destructive) { delete(project, targetId) }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: { _ in
                Text("只删除云电脑保存的项目记录，不会删除项目目录本身")
            }
            .onAppear { refresh(targetId) }
            .onChange(of: session.currentTarget) { _, _ in
                if let current = self.targetId { refresh(current) }
            }
        } else {
            ContentUnavailableView(
                "请选择在线云电脑",
                systemImage: "desktopcomputer",
                description: Text("项目保存在线客户端本机；服务器主机不提供此功能。")
            )
        }
    }

    private func list(_ targetId: String) -> some View {
        List(projects) { project in
            row(project, targetId: targetId)
        }
        .listStyle(.inset)
        .overlay {
            if !loading && projects.isEmpty && errorMessage == nil {
                ContentUnavailableView(
                    "暂无项目",
                    systemImage: "folder.badge.gearshape",
                    description: Text("把云电脑上的常用目录添加为项目，可快速打开目录或发起 Agent 会话")
                )
            }
        }
    }

    private func row(_ project: ProjectInfo, targetId: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                onOpenFiles(project.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在「文件」页打开该目录")
            if let onOpenDetail {
                Button {
                    onOpenDetail(project)
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.borderless)
                .help("打开项目详情（文件 / 终端 / Agent / 命令）")
            }
            Button {
                onNewAgent(project.path)
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("以此目录为工作目录新建 Agent 会话")
        }
        .padding(.vertical, 1)
        .contextMenu {
            if let onOpenDetail {
                Button { onOpenDetail(project) } label: {
                    Label("项目详情", systemImage: "square.grid.2x2")
                }
            }
            Button { onOpenFiles(project.path) } label: {
                Label("打开目录", systemImage: "folder")
            }
            Button { onNewAgent(project.path) } label: {
                Label("新建 Agent 会话", systemImage: "sparkles")
            }
            Divider()
            Button("拷贝路径") { copy(project.path) }
            Divider()
            Button {
                editSheet = ProjectEditSheet(project: project, targetId: targetId)
            } label: {
                Label("编辑…", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                confirmDelete = project
            } label: {
                Label("删除…", systemImage: "trash")
            }
        }
    }

    // MARK: 数据操作

    private func refresh(_ targetId: String) {
        loading = true
        session.listProjects(targetId: targetId) { error, list in
            loading = false
            errorMessage = error
            if error == nil { projects = list }
        }
    }

    private func delete(_ project: ProjectInfo, _ targetId: String) {
        session.deleteProject(targetId: targetId, projectId: project.id) { error, list in
            errorMessage = error
            if error == nil { projects = list }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 项目详情：一个项目的专属工作区（文件 / 终端 / Agent / 命令）

struct ProjectDetailView: View {
    let session: LinkSession
    let project: ProjectInfo
    var onClose: () -> Void

    enum Tab: Hashable {
        case files, terminal, agent, commands, git
    }

    @State private var tab: Tab = .files
    @State private var branch: String? // git 项目当前分支（非 git 项目为 nil）

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .help("返回项目列表")
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.headline).lineLimit(1)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let branch {
                    // git 项目显示当前分支（detached HEAD 时为短 hash）
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                        .help("当前分支")
                }
                Spacer()
                Picker("功能", selection: $tab) {
                    Text("文件").tag(Tab.files)
                    Text("终端").tag(Tab.terminal)
                    Text("Agent").tag(Tab.agent)
                    Text("命令").tag(Tab.commands)
                    Text("Git").tag(Tab.git)
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .files:
                FileBrowserView(session: session, initialDir: project.path)
            case .terminal:
                TerminalView(session: session, cwd: project.path)
            case .agent:
                // 只传过滤、不传 initialCwd：默认显示该项目的会话列表而非新建态
                AgentView(session: session, projectCwd: project.path)
            case .commands:
                TerminalCommandView(session: session) { command in
                    session.submit(command, cwd: project.path)
                    tab = .terminal
                }
            case .git:
                GitView(session: session, projectPath: project.path)
            }
        }
        .onAppear(perform: loadBranch)
    }

    // git 项目探测当前分支；非 git 项目保持 nil 不显示
    private func loadBranch() {
        session.runCommand(
            "(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)",
            cwd: project.path
        ) { out, error in
            let text = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            branch = (error == nil && !text.isEmpty) ? text : nil
        }
    }
}

// MARK: - 添加 / 编辑项目（保存在目标客户端本机）

private struct ProjectEditView: View {
    @Environment(\.dismiss) private var dismiss
    let session: LinkSession
    let sheet: ProjectView.ProjectEditSheet

    @State private var name = ""
    @State private var path = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(sheet.project == nil ? "添加项目" : "编辑项目") {
                    TextField("名称（可选，默认用目录名）", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("目录（如 ~/projects/app）", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
                Section {
                    Text("项目是云电脑上的常用目录，保存在客户端本机。保存后可在项目页快速打开目录或发起 Agent 会话。")
                        .font(.footnote)
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
                    .disabled(busy)
                Button(sheet.project == nil ? "添加" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || busy)
            }
            .padding(16)
        }
        .frame(width: 460, height: 260)
        .onAppear {
            if let project = sheet.project {
                name = project.name
                path = project.path
            }
        }
    }

    private var isValid: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        busy = true
        errorMessage = nil
        session.saveProject(
            targetId: sheet.targetId,
            projectId: sheet.project?.projectId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            path: path.trimmingCharacters(in: .whitespacesAndNewlines)
        ) { error, _ in
            busy = false
            if let error { errorMessage = error } else { dismiss() }
        }
    }
}


// MARK: - Git（项目详情）：变更（已暂存 / 未暂存）与提交列表

private struct GitChange: Identifiable {
    let code: String // 两字符状态码（如 "M "、" M"、"??")
    let path: String
    var id: String { "\(code)-\(path)" }

    // 状态码 -> 摘要（M 修改 / A 新增 / D 删除 / R 重命名 / ? 未跟踪）
    var summary: String {
        let c = code.trimmingCharacters(in: .whitespaces)
        return c == "??" ? "未跟踪" : c
    }
}

private struct GitCommit: Identifiable {
    let hash: String
    let author: String
    let date: String
    let subject: String
    var id: String { hash }
}

struct GitView: View {
    let session: LinkSession
    let projectPath: String

    enum SubTab: Hashable {
        case changes, log
    }

    @State private var subTab: SubTab = .changes
    @State private var staged: [GitChange] = []
    @State private var unstaged: [GitChange] = []
    @State private var commits: [GitCommit] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var copiedHash = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Git 视图", selection: $subTab) {
                Text("变更").tag(SubTab.changes)
                Text("提交").tag(SubTab.log)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .padding(.vertical, 8)
            Divider()
            if let errorMessage {
                VStack(spacing: 10) {
                    Text("读取失败").font(.headline)
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                    Button("重试", action: refresh)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading && staged.isEmpty && unstaged.isEmpty && commits.isEmpty {
                ProgressView("读取中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch subTab {
                case .changes: changesView
                case .log: logView
                }
            }
        }
        .toolbar {
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .help("刷新 Git 状态")
                .disabled(loading)
        }
        .onAppear { if staged.isEmpty && commits.isEmpty { refresh() } }
        .onChange(of: subTab) { _, _ in refresh() }
    }

    // 变更：已暂存（上）/ 未暂存（下），各占一半
    private var changesView: some View {
        VStack(spacing: 0) {
            changePane(title: "已暂存", changes: staged, tint: .green)
            Divider()
            changePane(title: "未暂存", changes: unstaged, tint: .orange)
        }
    }

    private func changePane(title: String, changes: [GitChange], tint: Color) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(title)（\(changes.count)）")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            List(changes) { change in
                HStack(spacing: 8) {
                    Text(change.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(tint)
                        .frame(width: 52, alignment: .leading)
                    Text(change.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
            .listStyle(.plain)
        }
        .frame(maxHeight: .infinity)
    }

    // 提交列表（limit 100，避免大仓库全量拉取）
    private var logView: some View {
        List(commits) { commit in
            HStack(spacing: 8) {
                Text(copiedHash ? "已复制" : commit.hash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.hash, forType: .string)
                        copiedHash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedHash = false }
                    }
                    .help("点击复制提交号")
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject).lineLimit(1)
                    Text("\(commit.author) · \(commit.date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 1)
        }
        .listStyle(.plain)
        .overlay {
            if commits.isEmpty && !loading {
                ContentUnavailableView("暂无提交", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private func refresh() {
        loading = true
        errorMessage = nil
        let group = DispatchGroup()

        // 状态：XY 两字符，X = 已暂存，Y = 工作区（?? = 未跟踪，归入未暂存）
        group.enter()
        session.runCommand("git status --porcelain", cwd: projectPath) { out, error in
            defer { group.leave() }
            if let error { errorMessage = error; return }
            var s: [GitChange] = []
            var u: [GitChange] = []
            for line in (out ?? "").split(separator: "\n") {
                let chars = Array(line)
                guard chars.count >= 3 else { continue }
                let code = String(chars[0...1])
                let path = String(chars[3...])
                if chars[0] != " " && chars[0] != "?" { s.append(GitChange(code: code, path: path)) }
                if chars[1] != " " || chars[0] == "?" { u.append(GitChange(code: code, path: path)) }
            }
            staged = s
            unstaged = u
        }

        // 提交：短号 / 作者 / 日期 / 标题，最多 100 条
        group.enter()
        session.runCommand("git log --max-count=100 --date=short --pretty=format:%h%x1f%an%x1f%ad%x1f%s", cwd: projectPath) { out, error in
            defer { group.leave() }
            if let error { errorMessage = error; return }
            commits = (out ?? "").split(separator: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\u{1f}")
                guard parts.count >= 4 else { return nil }
                return GitCommit(hash: parts[0], author: parts[1], date: parts[2], subject: parts[3...].joined(separator: "\u{1f}"))
            }
        }

        group.notify(queue: .main) { loading = false }
    }
}
