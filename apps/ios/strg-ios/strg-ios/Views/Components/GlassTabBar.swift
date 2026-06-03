import SwiftUI

// MARK: - Glass bottom tab bar

struct GlassTabBar: View {
    @Binding var active: AppTab

    var body: some View {
        HStack(spacing: 0) {
            tabItem(.scan,    systemImage: "viewfinder",  label: "Scan")
            tabItem(.history, systemImage: "calendar",    label: "History")
        }
        .padding(.top, 8)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .glassTabBar()
        .ignoresSafeArea(edges: .bottom)
    }

    private func tabItem(_ tab: AppTab, systemImage: String, label: String) -> some View {
        let on = active == tab
        return Button {
            withAnimation(StrgAnimation.buttonPress) { active = tab }
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
