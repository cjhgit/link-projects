import AppKit
import SwiftUI

/// 为 SwiftUI 创建的 NSSplitView 持久化分隔栏位置。
/// SwiftUI 切换 Tab 时会销毁并重建 HSplitView，因此除 AppKit 自动保存外，
/// 还需在每次拖动后立刻记录宽度，确保本次运行内也能正确恢复。
struct PersistedSplitView: NSViewRepresentable {
    let autosaveName: NSSplitView.AutosaveName

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attach(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(to: nsView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func attach(to view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let splitView = nearestSplitView(from: view) else { return }
            guard coordinator.splitView !== splitView || coordinator.autosaveName != autosaveName else { return }
            coordinator.stopObserving()
            splitView.autosaveName = autosaveName
            coordinator.splitView = splitView
            coordinator.autosaveName = autosaveName
            coordinator.restoreWidths()
            coordinator.startObserving()
        }
    }

    private func nearestSplitView(from view: NSView) -> NSSplitView? {
        sequence(first: view.superview, next: { $0?.superview })
            .compactMap { $0 as? NSSplitView }
            .first
    }

    final class Coordinator {
        weak var splitView: NSSplitView?
        var autosaveName: NSSplitView.AutosaveName?
        private var resizeObserver: NSObjectProtocol?

        private var storageKey: String? {
            autosaveName.map { "link-projects.split-view-widths.\($0)" }
        }

        func restoreWidths() {
            guard let splitView, let storageKey,
                  let widths = UserDefaults.standard.array(forKey: storageKey) as? [Double],
                  widths.count == splitView.subviews.count - 1 else { return }
            DispatchQueue.main.async {
                for (index, width) in widths.enumerated() {
                    splitView.setPosition(CGFloat(width), ofDividerAt: index)
                }
            }
        }

        func startObserving() {
            guard let splitView else { return }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: splitView,
                queue: .main
            ) { [weak self] _ in
                self?.saveWidths()
            }
        }

        func stopObserving() {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
        }

        private func saveWidths() {
            guard let splitView, let storageKey else { return }
            let widths = splitView.subviews.dropLast().map { Double($0.frame.width) }
            UserDefaults.standard.set(widths, forKey: storageKey)
        }

        deinit { stopObserving() }
    }
}

extension View {
    /// 持久化当前视图所在分隔布局的用户调整宽度。
    func persistedSplitView(_ autosaveName: NSSplitView.AutosaveName) -> some View {
        background(PersistedSplitView(autosaveName: autosaveName))
    }
}
