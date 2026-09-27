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
    @State private var confirmDelete = false
    @State private var deleteCandidate: ProjectInfo?

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
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(projects) { project in
                        row(project, targetId: targetId)
                    }
                } footer: {
                    Text("项目是云电脑上的常用目录，保存在客户端本机")
                }
            }
            .overlay {
                if loading && projects.isEmpty {
                    ProgressView("读取中…")
                } else if projects.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "暂无项目",
                        systemImage: "folder.badge.gearshape",
                        description: Text("点右上角 + 添加常用目录，之后可快速打开目录或发起 Agent 会话")
                    )
                }
            }
            .navigationTitle("项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        editSheet = ProjectEditSheet(project: nil, targetId: targetId)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加项目")
                    Button {
                        refresh(targetId)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .accessibilityLabel("刷新项目列表")
                }
            }
            .sheet(item: $editSheet, onDismiss: { refresh(targetId) }) { sheet in
                ProjectEditView(session: session, sheet: sheet)
            }
            .confirmationDialog(
                "删除项目",
                isPresented: $confirmDelete,
                titleVisibility: .automatic
            ) {
                Button("删除（不会删除项目目录）", role: .destructive) {
                    if let project = deleteCandidate { delete(project, targetId) }
                    deleteCandidate = nil
                }
                Button("取消", role: .cancel) { deleteCandidate = nil }
            } message: {
                Text("只删除云电脑保存的项目记录，项目目录本身不受影响")
            }
            .onAppear { refresh(targetId) }
            .onChange(of: session.currentTarget) { _, _ in
                if let current = self.targetId { refresh(current) }
            }
        } else {
            ContentUnavailableView(
                "请选择在线云电脑",
                systemImage: "desktopcomputer",
                description: Text("项目保存在线客户端本机。")
            )
        }
    }

    private func row(_ project: ProjectInfo, targetId: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
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
            .accessibilityLabel("打开目录")
            Button {
                onNewAgent(project.path)
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("新建 Agent 会话")
        }
        .font(.callout)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteCandidate = project
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editSheet = ProjectEditSheet(project: project, targetId: targetId)
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                onOpenFiles(project.path)
            } label: {
                Label("打开目录", systemImage: "folder")
            }
            Button {
                onNewAgent(project.path)
            } label: {
                Label("新建 Agent 会话", systemImage: "sparkles")
            }
            Divider()
            Button {
                UIPasteboard.general.string = project.path
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                editSheet = ProjectEditSheet(project: project, targetId: targetId)
            } label: {
                Label("编辑…", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                deleteCandidate = project
                confirmDelete = true
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
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section(sheet.project == nil ? "添加项目" : "编辑项目") {
                    TextField("名称（可选，默认用目录名）", text: $name)
                    TextField("目录（如 ~/projects/app）", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.callout, design: .monospaced))
                }
                Section {
                    Text("项目是云电脑上的常用目录，保存在客户端本机。保存后可在项目页快速打开目录或发起 Agent 会话。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(sheet.project == nil ? "添加项目" : "编辑项目")
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
                        Button(sheet.project == nil ? "添加" : "保存", action: save)
                            .disabled(!isValid)
                            .bold()
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
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
