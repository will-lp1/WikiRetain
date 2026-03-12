import SwiftUI

struct ReviewQueueView: View {
    @EnvironmentObject var appState: AppState
    @State private var dueCards: [SRSCard] = []
    @State private var currentIndex = 0
    @State private var isReviewing = false
    @State private var sessionComplete = false
    @State private var stats: ReviewService.ReviewStats?

    var body: some View {
        NavigationStack {
            Group {
                if dueCards.isEmpty {
                    NothingDueView(stats: stats)
                } else if sessionComplete {
                    SessionCompleteView(stats: appState.reviewService.stats()) {
                        resetSession()
                    }
                } else if isReviewing {
                    ReviewSessionView(
                        cards: dueCards,
                        currentIndex: $currentIndex,
                        onComplete: {
                            sessionComplete = true
                            appState.reviewService.refreshDueCount()
                        }
                    )
                } else {
                    ReviewReadyView(count: dueCards.count, onStart: {
                        currentIndex = 0
                        isReviewing = true
                    })
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.large)
            .task { await loadQueue() }
        }
    }

    private func loadQueue() async {
        dueCards = appState.reviewService.dueQueue()
        stats = appState.reviewService.stats()
    }

    private func resetSession() {
        isReviewing = false
        sessionComplete = false
        Task { await loadQueue() }
    }
}

// MARK: - Ready

private struct ReviewReadyView: View {
    let count: Int
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "brain.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            VStack(spacing: 12) {
                Text("\(count) article\(count == 1 ? "" : "s") due")
                    .font(.title.bold())
                Text("Quiz first, then you can re-read the article. This is the testing effect — proven to be more effective than re-reading alone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
            Button(action: onStart) {
                Text("Start Review")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

// MARK: - Nothing Due

private struct NothingDueView: View {
    let stats: ReviewService.ReviewStats?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("All caught up!")
                .font(.title.bold())
            Text("Nothing due for review today. Come back tomorrow.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let stats {
                VStack(spacing: 8) {
                    StatBadge(value: "\(stats.streak) days", label: "Current streak")
                    StatBadge(value: "\(Int(stats.retentionRate * 100))%", label: "Retention rate")
                }
            }
            Spacer()
        }
    }
}

private struct StatBadge: View {
    let value: String
    let label: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Session Complete

private struct SessionCompleteView: View {
    let stats: ReviewService.ReviewStats
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "party.popper.fill")
                .font(.system(size: 64))
                .foregroundStyle(.yellow)
            Text("Session complete!")
                .font(.title.bold())
            VStack(spacing: 16) {
                StatRow(label: "Retention rate", value: "\(Int(stats.retentionRate * 100))%",
                        color: stats.retentionRate > 0.8 ? .green : .orange)
                StatRow(label: "Streak", value: "\(stats.streak) days", color: .blue)
                StatRow(label: "Corpus retained", value: "\(Int(stats.corpusRetained * 100))%",
                        color: .purple)
            }
            .padding(.horizontal)
            Spacer()
            Button(action: onRestart) {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.headline).foregroundStyle(color)
        }
    }
}
