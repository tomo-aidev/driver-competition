import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @StateObject private var shotStore = ShotStore()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(AppTheme.surface)
        appearance.shadowColor = .clear

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(AppTheme.onSurfaceVariant),
            .font: UIFont.systemFont(ofSize: 10, weight: .medium)
        ]
        let selectedAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor(AppTheme.primaryFixed),
            .font: UIFont.systemFont(ofSize: 10, weight: .bold)
        ]

        appearance.stackedLayoutAppearance.normal.titleTextAttributes = normalAttributes
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = selectedAttributes
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(AppTheme.onSurfaceVariant)
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(AppTheme.primaryFixed)

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(shotStore: shotStore, switchToHistory: { selectedTab = 1 })
                .tabItem {
                    Image(systemName: "video.fill")
                    Text(String(localized: "tab_record", defaultValue: "Record"))
                }
                .tag(0)

            HistoryView(shotStore: shotStore)
                .tabItem {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(String(localized: "tab_history", defaultValue: "History"))
                }
                .tag(1)

            AnalysisView(shotStore: shotStore)
                .tabItem {
                    Image(systemName: "chart.xyaxis.line")
                    Text(String(localized: "tab_analysis", defaultValue: "Analysis"))
                }
                .tag(2)
        }
        .preferredColorScheme(.dark)
    }
}
