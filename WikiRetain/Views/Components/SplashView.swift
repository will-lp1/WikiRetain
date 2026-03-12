import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            Text("WikiRetain")
                .font(.largeTitle.bold())
            ProgressView()
                .tint(.blue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
