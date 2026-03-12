import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var recentArticles: [Article] = []
    @State private var stats: ReviewService.ReviewStats?
    @State private var selectedArticle: Article?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Due today banner
                    if appState.reviewService.dueCount > 0 {
                        DueBanner(count: appState.reviewService.dueCount) {
                            appState.selectedTab = .review
                        }
                    }

                    // Stats strip
                    if let stats {
                        StatsStrip(stats: stats)
                    }

                    // Continue reading
                    if let last = recentArticles.first {
                        SectionHeader(title: "Continue Reading")
                        ArticleCard(article: last) {
                            selectedArticle = last
                        }
                        .padding(.horizontal)
                    }

                    // Recent articles
                    if recentArticles.count > 1 {
                        SectionHeader(title: "Recently Read")
                        ForEach(recentArticles.dropFirst()) { article in
                            ArticleRow(article: article) {
                                selectedArticle = article
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Empty state
                    if recentArticles.isEmpty {
                        EmptyHomeState()
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("WikiRetain")
            .navigationBarTitleDisplayMode(.large)
            .task { await loadData() }
            .refreshable { await loadData() }
            .navigationDestination(item: $selectedArticle) { article in
                ArticleView(article: article)
            }
        }
    }

    private func loadData() async {
        recentArticles = await appState.articleService.recentlyRead(limit: 10)
        stats = appState.reviewService.stats()
    }
}

// MARK: - Components

private struct DueBanner: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "arrow.clockwise.heart.fill")
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) article\(count == 1 ? "" : "s") due for review")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text("Start your daily review")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding()
            .background(.orange)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal)
    }
}

private struct StatsStrip: View {
    let stats: ReviewService.ReviewStats

    var body: some View {
        HStack(spacing: 0) {
            StatCell(value: "\(Int(stats.retentionRate * 100))%", label: "Retention")
            Divider().frame(height: 40)
            StatCell(value: "\(stats.streak)", label: "Day Streak")
            Divider().frame(height: 40)
            StatCell(value: "\(Int(stats.corpusRetained * 100))%", label: "Corpus")
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

private struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal)
    }
}

private struct ArticleCard: View {
    let article: Article
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Text(article.title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(article.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack {
                    if let cat = article.category {
                        Label(cat, systemImage: "tag.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    ProgressView(value: article.lastScrollFrac)
                        .frame(width: 80)
                }
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct ArticleRow: View {
    let article: Article
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let cat = article.category {
                        Text(cat)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyHomeState: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start exploring")
                .font(.title3.bold())
            Text("Search for a Wikipedia article to begin building your knowledge graph.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Browse Articles") {
                appState.selectedTab = .search
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }
}
