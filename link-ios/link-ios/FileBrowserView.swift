import SwiftUI
import UIKit

// 详情区工作模式：项目 / 终端 / 文件浏览器（对当前选中的客户端）
enum DetailTab: Hashable {
    case projects
    case terminal
    case files
    case agent
}

// MARK: - 文件浏览器（浏览当前目标的目录：客户端或服务器主机 @server，点击目录进入、点击文件打开查看/编辑）
// 移动端为 push 导航：后退/前进交给系统导航，起始层在切换目标客户端时重置

struct FileBrowserView: View {
    let session: LinkSession
    let path: String // 要加载的目录（~ 为客户端家目录）

    // 起始层（工作区直接构造）在切换目标客户端时重置目录；push 进来的子层不重置
    @State private var resetsOnTargetChange: Bool
    @State private var realPath = "" // 展开后的实际路径，空 = 未加载
    @State private var entries: [FileEntryInfo] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showHidden = false
    @State private var pushDir: String? // 程序化跳转 push 的子目录
    @State private var viewer: FileViewerSheet?
    @State private var showCreateFile = false // 新建文本文件弹窗
    @State private var newFileName = ""
    @State private var confirmDelete = false // 删除确认弹窗
    @State private var entryPendingDelete: FileEntryInfo?
    @State private var showJump = false // 路径跳转弹窗
    @State private var jumpPath = ""

    struct FileViewerSheet: Identifiable {
        let path: String
        let id = UUID()
    }

    init(session: LinkSession, path: String, resetsOnTargetChange: Bool = false) {
        self.session = session
        self.path = path
        _resetsOnTargetChange = State(initialValue: resetsOnTargetChange)
    }

    var body: some View {
        Group {
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
                    description: Text("请返回列表选择要浏览的客户端")
                )
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if realPath.isEmpty { load(path) } }
        .onChange(of: session.currentTarget) { _, _ in
            // 切换目标客户端后浏览另一台机器，起始层目录重置
            guard resetsOnTargetChange else { return }
            realPath = ""
            entries = []
            errorMessage = nil
            load("~")
        }
    }

    private var navigationTitle: String {
        if realPath.isEmpty { return "文件" }
        return (realPath as NSString).lastPathComponent.isEmpty ? realPath : (realPath as NSString).lastPathComponent
    }

    private var browser: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section {
                ForEach(visibleEntries) { entry in
                    row(entry)
                }
            } header: {
                if !realPath.isEmpty {
                    // 当前目录完整路径（可长按选中拷贝）
                    Text(realPath)
                        .font(.caption2.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .overlay {
            if loading {
                ProgressView("读取中…")
            } else if visibleEntries.isEmpty && errorMessage == nil {
                ContentUnavailableView("空目录", systemImage: "folder")
            }
        }
        .navigationDestination(item: $pushDir) { dir in
            FileBrowserView(session: session, path: dir)
        }
        .sheet(item: $viewer, onDismiss: {
            // 查看器可能保存过文件（大小/时间变化），关闭后刷新当前目录
            if !realPath.isEmpty { load(realPath) }
        }) { sheet in
            FileViewerView(session: session, path: sheet.path)
        }
        .alert("新建文本文件", isPresented: $showCreateFile) {
            TextField("文件名", text: $newFileName)
            Button("创建") { createFile(named: newFileName) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录创建空文件，同名文件或目录已存在时会失败")
        }
        .alert("跳转目录", isPresented: $showJump) {
            TextField("绝对路径（~ 为家目录）", text: $jumpPath)
            Button("跳转") {
                let target = jumpPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty { pushDir = target }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入客户端上的目录绝对路径，~ 表示客户端家目录")
        }
        .confirmationDialog(
            "删除",
            isPresented: $confirmDelete,
            titleVisibility: .automatic,
            presenting: entryPendingDelete
        ) { entry in
            Button("删除“\(entry.name)”", role: .destructive) { deleteEntry(entry) }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text(entry.kind == .dir
                ? "目录“\(entry.name)”及其全部内容将被递归删除，此操作不可恢复"
                : "文件“\(entry.name)”将被删除，此操作不可恢复")
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if !realPath.isEmpty { load(realPath) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(realPath.isEmpty || loading)
                Menu {
                    Button {
                        newFileName = ""
                        showCreateFile = true
                    } label: {
                        Label("新建文本文件", systemImage: "doc.badge.plus")
                    }
                    .disabled(realPath.isEmpty || loading)
                    Button {
                        showHidden.toggle()
                    } label: {
                        Label(
                            showHidden ? "隐藏点开头的文件" : "显示全部文件",
                            systemImage: showHidden ? "eye.slash" : "eye"
                        )
                    }
                    Button {
                        jumpPath = ""
                        showJump = true
                    } label: {
                        Label("跳转路径…", systemImage: "arrow.up.forward")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var visibleEntries: [FileEntryInfo] {
        entries.filter { showHidden || !$0.name.hasPrefix(".") }
    }

    // MARK: 列表行与交互

    private func row(_ entry: FileEntryInfo) -> some View {
        Button {
            let full = (realPath as NSString).appendingPathComponent(entry.name)
            switch entry.kind {
            case .dir:
                pushDir = full
            case .file:
                viewer = FileViewerSheet(path: full)
            case .other:
                break
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(entry.kind == .dir ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if entry.kind == .file {
                            Text(FileFormat.size(entry.size))
                                .monospacedDigit()
                        }
                        if entry.mtime > 0 {
                            Text(FileFormat.time(entry.mtime))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.kind == .dir {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                entryPendingDelete = entry
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            if entry.kind == .dir {
                Button {
                    pushDir = (realPath as NSString).appendingPathComponent(entry.name)
                } label: {
                    Label("打开", systemImage: "folder")
                }
            } else if entry.kind == .file {
                Button {
                    viewer = FileViewerSheet(path: (realPath as NSString).appendingPathComponent(entry.name))
                } label: {
                    Label("查看 / 编辑…", systemImage: "doc.text")
                }
            }
            Divider()
            Button {
                copy((realPath as NSString).appendingPathComponent(entry.name))
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                entryPendingDelete = entry
                confirmDelete = true
            } label: {
                Label("删除…", systemImage: "trash")
            }
        }
    }

    // MARK: 加载 / 新建 / 删除

    private func load(_ newPath: String) {
        loading = true
        errorMessage = nil
        session.listFiles(path: newPath) { result in
            loading = false
            switch result {
            case .ok(let (real, list)):
                realPath = real
                entries = list
            case .failed(let error):
                // 失败时保留原目录内容，用户可继续操作或修改路径
                errorMessage = "读取 \(newPath) 失败：\(error)"
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
        let full = (realPath as NSString).appendingPathComponent(name)
        session.createRemoteFile(path: full) { error in
            if let error {
                errorMessage = "新建 \(name) 失败：\(error)"
            } else {
                // 刷新目录并直接打开编辑器（新建文本文件后通常要立即写内容）
                load(realPath)
                viewer = FileViewerSheet(path: full)
            }
        }
    }

    private func deleteEntry(_ entry: FileEntryInfo) {
        let full = (realPath as NSString).appendingPathComponent(entry.name)
        session.deleteRemoteFile(path: full) { error in
            if let error {
                errorMessage = "删除 \(entry.name) 失败：\(error)"
            } else {
                load(realPath)
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
        UIPasteboard.general.string = text
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
        NavigationStack {
            VStack(spacing: 0) {
                editor
                Divider()
                footer
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存", action: save)
                            .disabled(!isDirty || readOnlyReason != nil || loading)
                            .bold()
                    }
                }
            }
        }
        .presentationDetents([.large])
        // 有未保存修改时禁止下拉关闭，避免误触丢失内容；关闭按钮会先确认
        .interactiveDismissDisabled(isDirty)
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
                // 路径与保存状态
                HStack(spacing: 8) {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    if let savedAt {
                        Text("已保存 \(savedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if isDirty {
                        Text("未保存")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if let readOnlyReason {
                    Text("\(readOnlyReason)，仅查看不可编辑")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                TextEditor(text: $content)
                    .font(.system(.callout, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("重新加载", action: reloadOrConfirm)
                .disabled(loading || saving)
        }
        .padding(12)
    }

    // MARK: 读取 / 保存 / 关闭

    private func reload() {
        loading = true
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
