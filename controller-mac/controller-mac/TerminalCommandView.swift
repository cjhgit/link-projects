import SwiftUI
import AppKit

/// 常用命令保存在当前目标 client 的 ~/.link-projects/terminal-commands.json。
struct TerminalCommandView: View {
    let session: LinkSession
    let onRun: (String) -> Void
    @State private var commands: [TerminalCommandInfo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var editing: TerminalCommandInfo?
    @State private var adding = false

    private var targetId: String? {
        guard let id = session.currentTarget, id != LinkSession.serverTargetId,
              session.onlineClients.contains(where: { $0.clientId == id }) else { return nil }
        return id
    }

    var body: some View {
        if let targetId {
            List(commands) { item in
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).lineLimit(1)
                        Text(item.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { onRun(item.command) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("在终端执行")
                }
                .contextMenu {
                    Button { onRun(item.command) } label: { Label("在终端执行", systemImage: "play.fill") }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.command, forType: .string) } label: { Label("拷贝命令", systemImage: "doc.on.doc") }
                    Divider()
                    Button { editing = item } label: { Label("编辑…", systemImage: "square.and.pencil") }
                    Button(role: .destructive) { remove(item, targetId) } label: { Label("删除", systemImage: "trash") }
                }
            }
            .overlay { if loading && commands.isEmpty { ProgressView("读取中…") } else if !loading && commands.isEmpty && error == nil { ContentUnavailableView("暂无常用命令", systemImage: "terminal", description: Text("添加常用 shell 命令后，可在此一键执行")) } }
            .toolbar {
                Button { adding = true } label: { Image(systemName: "plus") }.help("添加常用命令")
                Button { refresh(targetId) } label: { Image(systemName: "arrow.clockwise") }.disabled(loading)
            }
            .sheet(isPresented: $adding, onDismiss: { refresh(targetId) }) { TerminalCommandEditView(session: session, targetId: targetId, command: nil) }
            .sheet(item: $editing, onDismiss: { refresh(targetId) }) { TerminalCommandEditView(session: session, targetId: targetId, command: $0) }
            .onAppear { refresh(targetId) }
            .onChange(of: session.currentTarget) { _, _ in if let id = self.targetId { refresh(id) } }
        } else {
            ContentUnavailableView("请选择在线云电脑", systemImage: "desktopcomputer", description: Text("常用命令保存在客户端本机。"))
        }
    }

    private func refresh(_ targetId: String) { loading = true; session.listTerminalCommands(targetId: targetId) { error, list in loading = false; self.error = error; if error == nil { commands = list } } }
    private func remove(_ item: TerminalCommandInfo, _ targetId: String) { session.deleteTerminalCommand(targetId: targetId, commandId: item.commandId) { error, list in self.error = error; if error == nil { commands = list } } }
}

private struct TerminalCommandEditView: View {
    @Environment(\.dismiss) private var dismiss
    let session: LinkSession; let targetId: String; let command: TerminalCommandInfo?
    @State private var name = ""; @State private var content = ""; @State private var error: String?; @State private var busy = false
    var body: some View {
        VStack(spacing: 0) {
            Form { Section(command == nil ? "添加常用命令" : "编辑常用命令") { TextField("名称（可选）", text: $name); TextField("命令", text: $content, axis: .vertical).font(.system(.callout, design: .monospaced)).lineLimit(3...8) }; if let error { Text(error).foregroundStyle(.red) } }
            HStack { Spacer(); Button("取消") { dismiss() }.disabled(busy); Button(command == nil ? "添加" : "保存") { save() }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy) }.padding()
        }.frame(width: 460, height: 270).onAppear { name = command?.name ?? ""; content = command?.command ?? "" }
    }
    private func save() { busy = true; session.saveTerminalCommand(targetId: targetId, commandId: command?.commandId, name: name, command: content) { error, _ in busy = false; if let error { self.error = error } else { dismiss() } } }
}
