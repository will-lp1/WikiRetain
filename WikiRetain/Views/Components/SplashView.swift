import SwiftUI

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
                .opacity(appeared || reduceMotion ? 1 : 0)
            Text("WikiRetain")
                .font(.largeTitle.bold())
                .opacity(appeared || reduceMotion ? 1 : 0)
            ProgressView()
                .tint(.blue)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear {
            withAnimation(Motion.easeOut.delay(0.05)) { appeared = true }
        }
    }
}
