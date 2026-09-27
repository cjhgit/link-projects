import SwiftUI

// 项目管理：项目 = 云电脑上的常用目录，数据由 client 保存在本机（同 Agent 会话）。
// 每个项目提供两个快捷入口：打开目录（跳「文件」页定位）、新建会话（跳「Agent」页预填工作目录）。
struct ProjectView: View {
    let session: LinkSession
    let onOpenFiles: (String) -> Void
    let onNewAgent: (String) -> Void

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
