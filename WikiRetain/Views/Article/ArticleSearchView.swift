import SwiftUI

struct ArticleSearchView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [Article] = []
    @State private var isSearching = false
    @State private var selectedArticle: Article?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && query.isEmpty {
                    SearchEmptyState()
                } else if results.isEmpty && !query.isEmpty && !isSearching {
                    NoResultsView(query: query)
                } else {
                    List(results) { article in
                        Button {
                            selectedArticle = article
                        } label: {
                            SearchResultRow(article: article)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search 50,000 Wikipedia articles")
            .overlay(alignment: .center) {
                if isSearching {
                    ProgressView().padding()
                }
            }
            .onChange(of: query) { _, newVal in
                searchTask?.cancel()
                guard !newVal.isEmpty else {
                    results = []
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
                    guard !Task.isCancelled else { return }
                    isSearching = true
                    results = await appState.articleService.search(query: newVal)
                    isSearching = false
                }
            }
            .navigationDestination(item: $selectedArticle) { article in
                ArticleView(article: article)
            }
        }
    }
}

private struct SearchResultRow: View {
    let article: Article

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(article.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if article.isRead {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            if let cat = article.category {
                Text(cat)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Text(article.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private struct SearchEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Search Wikipedia")
                .font(.title3.bold())
            Text("Full-text search across 50,000 vital articles")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoResultsView: View {
    let query: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No results for \"\(query)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
