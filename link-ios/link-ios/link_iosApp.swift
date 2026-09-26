//
//  link_iosApp.swift
//  link-ios
//
//  Created by yunser on 2026/9/26.
//

import SwiftUI

@main
struct link_iosApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear { model.connectAllIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    // 回到前台时重连被系统断开的会话（手动断开的不重连）
                    if phase == .active { model.reconnectOnForeground() }
                }
        }
    }
}
