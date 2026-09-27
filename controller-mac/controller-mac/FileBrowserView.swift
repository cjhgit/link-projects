import SwiftUI

// 详情区工作模式：项目 / 终端 / 文件浏览器（对当前选中的客户端）
enum DetailTab: Hashable {
    case projects
    case terminal
    case files
    case agent
}

// 已连接服务端的详情区：顶部切换项目 / 终端 / 文件 / Agent，各自独占剩余空间。
// 项目页发起的跳转（打开目录 / 新建会话）通过 filesDir / agentCwd 传给对应页面
struct WorkspaceView: View {
    let session: LinkSession
    @State private var tab: DetailTab = .projects
    @State private var filesDir: String? // 「文件」页要定位的目录（项目页发起）
    @State private var agentCwd: String? // 「Agent」页新建会话预填的工作目录（项目页发起）

    var body: some View {
        VStack(spacing: 0) {
            Picker("工作模式", selection: $tab) {
                Text("项目").tag(DetailTab.projects)
                Text("终端").tag(DetailTab.terminal)
                Text("文件").tag(DetailTab.files)
                Text("Agent").tag(DetailTab.agent)
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
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
                FileBrowserView(session: session, initialDir: filesDir ?? "~")
            case .agent:
                AgentView(session: session, initialCwd: agentCwd)
            }
        }
        // 切换目标客户端后，项目页留下的定位目录 / 工作目录属于另一台机器，一并清掉
        .onChange(of: session.currentTarget) { _, _ in
            filesDir = nil
            agentCwd = nil
        }
    }
}

// MARK: - 文件浏览器（浏览当前目标的目录：客户端或服务器主机 @server，双击文件打开查看/编辑）

struct FileBrowserView: View {
    let session: LinkSession
    var initialDir: String = "~" // 起始目录（项目页跳转时为项目目录）

    @State private var path = "" // 当前目录（客户端展开 ~ 后的实际路径），空 = 未加载
    @State private var entries: [FileEntryInfo] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var backStack: [String] = []
    @State private var forwardStack: [String] = []
    @State private var pathInput = "" // 路径输入框，与当前目录同步，可手动跳转
    @State private var viewer: FileViewerSheet?
    @State private var showHidden = false
    @State private var showCreateFile = false // 新建文本文件弹窗
    @State private var newFileName = ""
    @State private var confirmDelete = false // 删除确认弹窗
    @State private var entryPendingDelete: FileEntryInfo?

    struct FileViewerSheet: Identifiable {
        let path: String
        let id = UUID()
    }

    var body: some View {
        if let target = session.currentTarget {
            if target == LinkSession.serverTargetId {
                // 服务器主机目标：浏览 server 本机文件，连接着即可（本视图只在已连接的工作区显示）
                browser
            } else if session.onlineClients.contains(where: { $0.clientId == target }) {
                browser
            } else {
                ContentUnavailableView(
                    "客户端离线",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("“\(target)”当前不在线，无法浏览文件")
                )
            }
        } else {
            ContentUnavailableView(
                "未选择客户端",
                systemImage: "folder",
                description: Text("请先在中间列表选择要浏览的客户端")
            )
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            if let transfer = session.transfer {
                transferBar(transfer)
                Divider()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            listView
        }
        .sheet(item: $viewer) { sheet in
            FileViewerView(session: session, path: sheet.path)
                .onDisappear {
                    // 查看器可能保存过文件（大小/时间变化），关闭后刷新当前目录
                    if !path.isEmpty { load(path) }
                }
        }
        .alert("新建文本文件", isPresented: $showCreateFile) {
            TextField("文件名", text: $newFileName)
            Button("创建") { createFile(named: newFileName) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录创建空文件，同名文件或目录已存在时会失败")
        }
        .confirmationDialog(
            "删除",
            isPresented: $confirmDelete,
            presenting: entryPendingDelete
        ) { entry in
            Button("删除“\(entry.name)”", role: .destructive) { deleteEntry(entry) }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text(entry.kind == .dir
                ? "目录“\(entry.name)”及其全部内容将被递归删除，此操作不可恢复"
                : "文件“\(entry.name)”将被删除，此操作不可恢复")
        }
        .onAppear { if path.isEmpty { load(initialDir) } }
        // 项目页发起定位时视图可能未销毁重建，监听起始目录变化
        .onChange(of: initialDir) { _, newDir in
            guard newDir != path else { return }
            navigate(newDir)
        }
        .onChange(of: session.currentTarget) { _, _ in
            // 切换目标客户端后浏览另一台机器，目录与历史全部重置
            path = ""
            entries = []
            errorMessage = nil
            backStack = []
            forwardStack = []
            load("~")
        }
    }

    // MARK: 导航栏：后退 / 前进 / 上级 / 路径跳转 / 刷新 / 隐藏文件

    private var navBar: some View {
        HStack(spacing: 8) {
            Button {
                guard let previous = backStack.popLast() else { return }
                forwardStack.append(path)
                load(previous)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(backStack.isEmpty)

            Button {
                guard let next = forwardStack.popLast() else { return }
                backStack.append(path)
                load(next)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(forwardStack.isEmpty)

            Button {
                let parent = (path as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != path else { return }
                navigate(parent)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(path.isEmpty || path == "/")
            .help("上一级目录")

            TextField("路径（回车跳转，~ 为客户端家目录）", text: $pathInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .onSubmit {
                    let target = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty, target != path else { return }
                    navigate(target)
                }

            Button {
                newFileName = ""
                showCreateFile = true
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .disabled(path.isEmpty || loading)
            .help("新建文本文件")

            Button(action: pickAndUpload) {
                Image(systemName: "icloud.and.arrow.up")
            }
            .disabled(path.isEmpty || loading || session.transfer != nil || isServerTarget)
            .help(isServerTarget ? "上传仅支持云电脑客户端（服务器主机不支持）" : "上传本地文件到当前目录")

            Button {
                if !path.isEmpty { load(path) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(path.isEmpty || loading)
            .help("刷新")

            Button {
                showHidden.toggle()
            } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
            }
            .help(showHidden ? "显示全部文件" : "隐藏点开头的文件")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var listView: some View {
        let visible = entries.filter { showHidden || !$0.name.hasPrefix(".") }
        return List {
            ForEach(visible) { entry in
                row(entry)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        let full = (path as NSString).appendingPathComponent(entry.name)
                        switch entry.kind {
                        case .dir:
                            navigate(full)
                        case .file:
                            viewer = FileViewerSheet(path: full)
                        case .other:
                            break
                        }
                    }
                    .contextMenu {
                        if entry.kind == .dir {
                            Button("打开") { navigate((path as NSString).appendingPathComponent(entry.name)) }
                        } else if entry.kind == .file {
                            Button("查看 / 编辑…") { viewer = FileViewerSheet(path: (path as NSString).appendingPathComponent(entry.name)) }
                            Button("下载到本地…") { downloadToMac(entry) }
                                .disabled(session.transfer != nil || isServerTarget)
                        }
                        Divider()
                        Button("拷贝路径") { copy((path as NSString).appendingPathComponent(entry.name)) }
                        Divider()
                        Button("删除…", role: .destructive) {
                            entryPendingDelete = entry
                            confirmDelete = true
                        }
                    }
            }
        }
        .listStyle(.inset)
        .overlay {
            if loading {
                ProgressView("读取中…")
            } else if visible.isEmpty && errorMessage == nil {
                ContentUnavailableView("空目录", systemImage: "folder")
            }
        }
    }

    private func row(_ entry: FileEntryInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: entry.kind))
                .foregroundStyle(entry.kind == .dir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if entry.kind == .file {
                Text(FileFormat.size(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text(entry.kind == .dir ? "--" : "")
                    .frame(width: 80, alignment: .trailing)
            }
            Text(entry.mtime > 0 ? FileFormat.time(entry.mtime) : "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
        }
        .font(.system(.callout))
        .padding(.vertical, 1)
    }

    // MARK: 导航与加载

    // 上传 / 下载仅在云电脑客户端可用（@server 由 server 就地处理，不支持传输消息）
    private var isServerTarget: Bool {
        session.currentTarget == LinkSession.serverTargetId
    }

    // 跳转到新目录（记录历史，清空前进栈）
    private func navigate(_ newPath: String) {
        guard !loading else { return }
        if !path.isEmpty { backStack.append(path) }
        forwardStack.removeAll()
        load(newPath)
    }

    private func load(_ newPath: String) {
        loading = true
        errorMessage = nil
        session.listFiles(path: newPath) { result in
            loading = false
            switch result {
            case .ok(let (realPath, list)):
                path = realPath
                pathInput = realPath
                entries = list
            case .failed(let error):
                // 失败时保留原目录内容，用户可继续操作或修改路径
                errorMessage = "读取 \(newPath) 失败：\(error)"
                if path.isEmpty { pathInput = newPath }
            }
        }
    }

    // MARK: 新建 / 删除 / 上传 / 下载

    // 进度条：上传 / 下载共用（一次一个传输，进行中禁用新传输）
    private func transferBar(_ transfer: LinkSession.TransferInfo) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: transfer.isUpload ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                Text("\(transfer.isUpload ? "上传" : "下载") \(transfer.fileName)")
                    .lineLimit(1)
                Spacer()
                Text(transfer.total > 0
                     ? "\(FileFormat.size(Double(transfer.transferred))) / \(FileFormat.size(Double(transfer.total)))"
                     : FileFormat.size(Double(transfer.transferred)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if transfer.total > 0 {
                ProgressView(value: Double(transfer.transferred), total: Double(transfer.total))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // 选本地文件上传到当前目录（同名覆盖）
    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要上传到 \(path) 的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let remote = (path as NSString).appendingPathComponent(url.lastPathComponent)
        session.uploadFile(localURL: url, remotePath: remote) { error in
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let error {
                errorMessage = "上传 \(url.lastPathComponent) 失败：\(error)"
            } else {
                load(path) // 上传完成后刷新目录
            }
        }
    }

    // 下载远程文件到本机（NSSavePanel 选保存位置，同名覆盖）
    private func downloadToMac(_ entry: FileEntryInfo) {
        let full = (path as NSString).appendingPathComponent(entry.name)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.message = "保存从 \(path) 下载的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.downloadFile(remotePath: full, localURL: url) { error in
            if let error {
                errorMessage = "下载 \(entry.name) 失败：\(error)"
            }
        }
    }

    private func createFile(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只允许在当前目录下按文件名创建（含分隔符或目录引用的输入直接拒绝）
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            errorMessage = "文件名无效：\(name.isEmpty ? "为空" : name)"
            return
        }
        let full = (path as NSString).appendingPathComponent(name)
        session.createRemoteFile(path: full) { error in
            if let error {
                errorMessage = "新建 \(name) 失败：\(error)"
            } else {
                // 刷新目录并直接打开编辑器（新建文本文件后通常要立即写内容）
                load(path)
                viewer = FileViewerSheet(path: full)
            }
        }
    }

    private func deleteEntry(_ entry: FileEntryInfo) {
        let full = (path as NSString).appendingPathComponent(entry.name)
        session.deleteRemoteFile(path: full) { error in
            if let error {
                errorMessage = "删除 \(entry.name) 失败：\(error)"
            } else {
                load(path)
            }
        }
    }

    private func icon(for kind: FileEntryKind) -> String {
        switch kind {
        case .dir: "folder.fill"
        case .file: "doc"
        case .other: "questionmark.square.dashed"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 文件查看 / 编辑（读取远端内容，保存时写回；二进制与超大文件只读）

struct FileViewerView: View {
    let session: LinkSession
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var savedContent = "" // 最近一次读取/保存的内容，用于脏检测
    @State private var loading = false
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var savedAt: Date?
    @State private var readOnlyReason: String? // 二进制 / 超大文件只读的原因
    @State private var confirmClose = false
    @State private var confirmReload = false

    private var isDirty: Bool { content != savedContent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear(perform: reload)
        .confirmationDialog(
            "有未保存的修改",
            isPresented: $confirmClose,
            titleVisibility: .automatic
        ) {
            Button("放弃修改并关闭", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("关闭后未保存的修改将丢失")
        }
        .confirmationDialog(
            "放弃未保存的修改？",
            isPresented: $confirmReload,
            titleVisibility: .automatic
        ) {
            Button("放弃修改并重新加载", role: .destructive) { reload() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重新加载会覆盖当前编辑内容")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if let savedAt {
                Text("已保存 \(savedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if isDirty {
                Text("未保存")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var editor: some View {
        if loading {
            ProgressView("读取文件中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Text("读取失败")
                    .font(.headline)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("重试", action: reload)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let readOnlyReason {
                    Text("\(readOnlyReason)，仅查看不可编辑")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(alignment: .trailing) {
                            Button("重新加载", action: reload)
                                .padding(.trailing, 12)
                        }
                }
                TextEditor(text: $content)
                    .font(.system(.callout, design: .monospaced))
                    .disabled(readOnlyReason != nil)
                    .opacity(readOnlyReason != nil ? 0.5 : 1)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("重新加载", action: reloadOrConfirm)
                .disabled(loading || saving)
            Button("保存", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || saving || readOnlyReason != nil || loading)
            Button("关闭", action: close)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: 读取 / 保存 / 关闭

    private func reload() {        loading = true
        loadError = nil
        saveError = nil
        savedAt = nil
        session.readRemoteFile(path: path) { result in
            loading = false
            switch result {
            case .ok(let text):
                content = text
                savedContent = text
                readOnlyReason = Self.readOnlyReason(for: text)
            case .failed(let error):
                loadError = error
            }
        }
    }

    private func save() {
        saving = true
        saveError = nil
        session.writeRemoteFile(path: path, content: content) { error in
            saving = false
            if let error {
                saveError = error
            } else {
                savedContent = content
                savedAt = Date()
            }
        }
    }

    private func close() {
        if isDirty {
            confirmClose = true
        } else {
            dismiss()
        }
    }

    // 有未保存修改时先确认再重载
    private func reloadOrConfirm() {
        if isDirty {
            confirmReload = true
        } else {
            reload()
        }
    }

    // 二进制内容（utf8 解码出 NUL 或大量替换符）保存会损坏文件，超大文件编辑易卡顿，都设为只读
    private static func readOnlyReason(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.contains("\u{0}") { return "内容包含二进制数据" }
        let replacements = text.filter { $0 == "\u{FFFD}" }.count
        if Double(replacements) / Double(text.count) > 0.01 { return "内容疑似非 UTF-8 文本" }
        if text.count > 1_000_000 { return "文件超过 1M 字符" }
        return nil
    }
}

// MARK: - 文件信息格式化

enum FileFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func time(_ milliseconds: Double) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    static func size(_ bytes: Double) -> String {
        let value = Int(bytes)
        if value < 1024 { return "\(value) B" }
        let kb = Double(value) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}
