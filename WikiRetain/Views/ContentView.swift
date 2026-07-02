import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !appState.isInitialized {
                SplashView()
            } else if !appState.hasCorpus {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainRootView()
                    .transition(.opacity)
            }
        }
        .animation(Motion.adaptive(Motion.easeOut, reduceMotion: reduceMotion), value: appState.isInitialized)
        .animation(Motion.adaptive(Motion.easeOut, reduceMotion: reduceMotion), value: appState.hasCorpus)
    }
}
