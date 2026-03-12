import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppState.Tab.home)

            ArticleSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppState.Tab.search)

            ReviewQueueView()
                .tabItem {
                    Label("Review", systemImage: "arrow.clockwise.heart.fill")
                }
                .badge(appState.reviewService.dueCount > 0 ? appState.reviewService.dueCount : 0)
                .tag(AppState.Tab.review)

            MindMapView()
                .tabItem { Label("Mind Map", systemImage: "network") }
                .tag(AppState.Tab.mindMap)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppState.Tab.settings)
        }
        .task {
            appState.reviewService.refreshDueCount()
        }
    }
}
