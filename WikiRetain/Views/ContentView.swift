import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isInitialized {
                SplashView()
            } else if !appState.hasCorpus {
                OnboardingView()
            } else {
                MainRootView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isInitialized)
        .animation(.easeInOut(duration: 0.3), value: appState.hasCorpus)
    }
}
