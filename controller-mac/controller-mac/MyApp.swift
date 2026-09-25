import SwiftUI

@main struct MyApp: App {
    @State private var session = LinkSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
        .windowResizability(.contentMinSize)
    }
}
