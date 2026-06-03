import SwiftUI

@main
struct StrgApp: App {
    @State private var apiClient    = StrgAPIClient()
    @State private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiClient)
                .environment(sessionStore)
        }
    }
}
