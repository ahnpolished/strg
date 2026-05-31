import SwiftUI

@main
struct StrgApp: App {
    @State private var apiClient = StrgAPIClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiClient)
        }
    }
}
