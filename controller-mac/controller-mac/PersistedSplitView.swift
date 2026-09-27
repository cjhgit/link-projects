import AppKit
import SwiftUI

/// 持久化 SwiftUI 生成的 NSSplitView。
/// NavigationSplitView 在 macOS 上可能生成嵌套的 NSSplitView；每一层都保存除最后一栏外的
/// 分隔条位置，以保证窗口重开或右侧详情区变化时，所有左侧栏宽保持用户最后调整的值。
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
        // SwiftUI 会在当前更新周期内继续搭建 NavigationSplitView；延后至下一轮主循环，
        // 才能取得稳定的尺寸，避免把初始的临时宽度当作用户设置保存。
        DispatchQueue.main.async {
            coordinator.attach(splitViews: splitViews(around: view), baseName: String(autosaveName))
        }
    }

    private func splitViews(around view: NSView) -> [NSSplitView] {
        let ancestors = sequence(first: view.superview, next: { $0?.superview })
            .compactMap { $0 as? NSSplitView }
        guard let root = ancestors.last else { return [] }

        var result: [NSSplitView] = []
        func collect(from node: NSView) {
            if let splitView = node as? NSSplitView {
                result.append(splitView)
            }
            node.subviews.forEach(collect)
        }
        collect(from: root)
        return result
    }

    final class Coordinator {
        private final class SplitState {
            weak var splitView: NSSplitView?
            let storageKey: String
            var resizeObserver: NSObjectProtocol?

            init(splitView: NSSplitView, storageKey: String) {
                self.splitView = splitView
                self.storageKey = storageKey
            }
        }

        private var states: [SplitState] = []
        private var identity: [ObjectIdentifier] = []

        func attach(splitViews: [NSSplitView], baseName: String) {
            let newIdentity = splitViews.map(ObjectIdentifier.init)
            guard newIdentity != identity else { return }

            stopObserving()
            identity = newIdentity
            states = splitViews.enumerated().map { index, splitView in
                // 不启用 AppKit autosave，防止它和自定义恢复在启动阶段发生竞争。
                splitView.autosaveName = nil
                return SplitState(
                    splitView: splitView,
                    // v3 覆盖旧版错误的“栏宽”格式，也隔离此前只保存单层的记录。
                    storageKey: "link-projects.split-view-divider-positions.v3.\(baseName).\(index)"
                )
            }

            // 恢复完成前不监听 resize，避免恢复过程触发通知又把临时布局写回。
            DispatchQueue.main.async { [weak self] in
                self?.restoreDividerPositions()
                self?.startObserving()
            }
        }

        private func restoreDividerPositions() {
            for state in states {
                guard let splitView = state.splitView,
                      let positions = UserDefaults.standard.array(forKey: state.storageKey) as? [Double],
                      positions.count == splitView.subviews.count - 1 else { continue }
                for (index, position) in positions.enumerated() {
                    splitView.setPosition(CGFloat(position), ofDividerAt: index)
                }
            }
        }

        private func startObserving() {
            for state in states {
                guard let splitView = state.splitView else { continue }
                state.resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: splitView,
                    queue: .main
                ) { [weak self, weak state] _ in
                    guard let state else { return }
                    self?.saveDividerPositions(for: state)
                }
            }
        }

        private func stopObserving() {
            for state in states {
                if let observer = state.resizeObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                state.resizeObserver = nil
            }
        }

        private func saveDividerPositions(for state: SplitState) {
            guard let splitView = state.splitView else { return }
            let positions = (0..<(splitView.subviews.count - 1)).map {
                // 第 index 个子视图右边缘即第 index 根分隔条的绝对坐标，
                // 与 NSSplitView.setPosition(_:ofDividerAt:) 使用同一坐标体系。
                Double(splitView.subviews[$0].frame.maxX)
            }
            UserDefaults.standard.set(positions, forKey: state.storageKey)
        }

        deinit { stopObserving() }
    }
}

extension View {
    /// 持久化当前视图所在的整组嵌套分栏布局。
    func persistedSplitView(_ autosaveName: NSSplitView.AutosaveName) -> some View {
        background(PersistedSplitView(autosaveName: autosaveName))
    }
}
