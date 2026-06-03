import SwiftUI

// MARK: - Tab identifiers

enum AppTab { case scan, history }

// MARK: - Root view

struct ContentView: View {
    @State private var activeTab: AppTab = .scan
    @State private var showsTabBar = true

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
        .animation(.easeInOut(duration: 0.22), value: showsTabBar)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Glass tab bar

private struct GlassTabBar: View {
    @Binding var active: AppTab

    var body: some View {
        HStack(spacing: 0) {
            tabItem(.scan,    systemImage: "viewfinder",  label: "Scan")
            tabItem(.history, systemImage: "calendar",    label: "History")
        }
        .padding(.top, 8)
        // paddingBottom: 26 (design) — safe area bottom is handled by ignoresSafeArea + the
        // system adds inset on devices with home indicator automatically.
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.055).opacity(0.55)
                    .background(.ultraThinMaterial)
                VStack {
                    Color.white.opacity(0.08).frame(height: 0.5)
                    Spacer()
                }
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }

    private func tabItem(_ tab: AppTab, systemImage: String, label: String) -> some View {
        let on = active == tab
        return Button {
            active = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.strgAccent : Color.white.opacity(0.42))
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(on ? Color.strgAccent : Color.white.opacity(0.42))
                    .tracking(1.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(StrgAPIClient())
        .environment(SessionStore())
}
