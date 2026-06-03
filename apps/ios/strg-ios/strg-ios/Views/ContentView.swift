import SwiftUI

// MARK: - Tab identifiers

enum AppTab { case scan, history }

// MARK: - Root view

struct ContentView: View {
    @State private var activeTab: AppTab = .scan
    @State private var showsTabBar = true
    @State private var onboardingPrefs = OnboardingPreferences.load()
    @State private var showOnboarding = !OnboardingPreferences.isCompleted

    var body: some View {
        ZStack(alignment: .bottom) {
            // Both tab views always instantiated to preserve their state.
            // Only one is hittable at a time.
            Group {
                ScanTabView(showsTabBar: $showsTabBar)
                    .opacity(activeTab == .scan ? 1 : 0)
                    .allowsHitTesting(activeTab == .scan)

                HistoryView(showsTabBar: $showsTabBar)
                    .opacity(activeTab == .history ? 1 : 0)
                    .allowsHitTesting(activeTab == .history)
            }
            .ignoresSafeArea()

            // Glass tab bar — hides when a detail screen is active
            if showsTabBar {
                GlassTabBar(active: $activeTab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(StrgAnimation.tabBar, value: showsTabBar)
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { prefs in
                onboardingPrefs = prefs
                showOnboarding = false
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(StrgAPIClient())
        .environment(SessionStore())
}
