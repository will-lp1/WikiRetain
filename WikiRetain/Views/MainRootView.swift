import SwiftUI

// MARK: - Root

struct MainRootView: View {
    @EnvironmentObject var appState: AppState

    @State private var showBurgerMenu = false
    @State private var showQuizSheet = false
    @State private var showSearchSheet = false
    @State private var selectedArticle: Article?

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-screen mind map
                MindMapView()
                    .ignoresSafeArea()

                // HUD overlay
                VStack(spacing: 0) {
                    topHUD
                    Spacer()
                    bottomHUD
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationDestination(item: $selectedArticle) { article in
                ArticleView(article: article)
            }
        }
        .sheet(isPresented: $showBurgerMenu) {
            BurgerMenuSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showQuizSheet) {
            QuizHubSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchSheet(selectedArticle: $selectedArticle)
                .environmentObject(appState)
        }
        .task {
            appState.reviewService.refreshDueCount()
        }
    }

    // MARK: - Top HUD

    private var topHUD: some View {
        HStack(alignment: .center) {
            // Drop an "AppLogo" image asset to replace this placeholder
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 32)

            Spacer()

            Button {
                showBurgerMenu = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Bottom HUD

    private var bottomHUD: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Search bar pill
            Button {
                showSearchSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                    Text("Search or Chat…")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 17))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)

            // Quiz FAB with due-count badge
            Button {
                showQuizSheet = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Text("?")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))

                    if appState.reviewService.dueCount > 0 {
                        Text("\(appState.reviewService.dueCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                            .offset(x: 6, y: -6)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }
}

// MARK: - Burger Menu Sheet

private struct BurgerMenuSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SettingsView()
                            .environmentObject(appState)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                Section("Stats") {
                    let stats = appState.reviewService.stats()
                    HStack {
                        Label("Retention", systemImage: "chart.line.uptrend.xyaxis")
                        Spacer()
                        Text("\(Int(stats.retentionRate * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Streak", systemImage: "flame.fill")
                        Spacer()
                        Text("\(stats.streak) days")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Corpus retained", systemImage: "books.vertical.fill")
                        Spacer()
                        Text("\(Int(stats.corpusRetained * 100))%")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Library") {
                    HStack {
                        Label("Articles", systemImage: "doc.text")
                        Spacer()
                        Text(appState.corpusArticleCount.formatted())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Apple Intelligence", systemImage: "brain")
                        Spacer()
                        Text(appState.aiAvailable ? "Available" : "Not enabled")
                            .foregroundStyle(appState.aiAvailable ? .green : .secondary)
                    }
                }
            }
            .navigationTitle("WikiRetain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Quiz Hub Sheet

private struct QuizHubSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var dueCards: [SRSCard] = []
    @State private var showReviewSession = false
    @State private var newQuizTopic = ""
    @State private var isGeneratingQuiz = false
    @State private var generatedArticle: Article?

    var body: some View {
        NavigationStack {
            List {
                // Due reviews
                Section {
                    if dueCards.isEmpty {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All caught up!")
                                    .font(.headline)
                                Text("Nothing due for review today.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 14) {
                            Image(systemName: "brain.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dueCards.count) article\(dueCards.count == 1 ? "" : "s") due")
                                    .font(.headline)
                                Text("Quiz first — then re-read.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        Button {
                            showReviewSession = true
                        } label: {
                            Label("Start Review", systemImage: "play.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Due for Retention")
                }

                // New quiz with AI
                Section {
                    TextField("Topic or article name (optional)", text: $newQuizTopic)
                        .textInputAutocapitalization(.sentences)

                    Button {
                        generateNewQuiz()
                    } label: {
                        if isGeneratingQuiz {
                            HStack {
                                ProgressView()
                                Text("Finding article…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label(
                                appState.aiAvailable ? "Generate Quiz with AI" : "Find Article",
                                systemImage: appState.aiAvailable ? "wand.and.stars" : "magnifyingglass"
                            )
                        }
                    }
                    .disabled(isGeneratingQuiz)
                } header: {
                    Text("New Quiz")
                } footer: {
                    if !appState.aiAvailable {
                        Text("Enable Apple Intelligence to generate AI quizzes.")
                    } else {
                        Text("AI generates a fresh quiz from any article in your library.")
                    }
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadQueue() }
            .sheet(isPresented: $showReviewSession) {
                ReviewQueueView()
                    .environmentObject(appState)
            }
            .sheet(item: $generatedArticle) { article in
                NavigationStack {
                    ArticleView(article: article)
                        .environmentObject(appState)
                }
            }
        }
    }

    private func loadQueue() async {
        dueCards = appState.reviewService.dueQueue()
    }

    private func generateNewQuiz() {
        isGeneratingQuiz = true
        Task {
            defer { isGeneratingQuiz = false }
            let query = newQuizTopic.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let results = await appState.articleService.search(query: query)
                generatedArticle = results.first
            } else if let card = dueCards.first {
                generatedArticle = await appState.articleService.article(id: card.articleId)
            }
        }
    }
}

// MARK: - Search Sheet

private struct SearchSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedArticle: Article?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [Article] = []
    @State private var recentArticles: [Article] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var localSelection: Article?

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    recentList
                } else if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search or Chat…"
            )
            .onChange(of: query) { _, newVal in
                searchTask?.cancel()
                guard !newVal.isEmpty else { results = []; return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    isSearching = true
                    results = await appState.articleService.search(query: newVal)
                    isSearching = false
                }
            }
            .navigationDestination(item: $localSelection) { article in
                ArticleView(article: article)
                    .onDisappear {
                        selectedArticle = article
                        dismiss()
                    }
            }
        }
        .task {
            recentArticles = await appState.articleService.recentlyRead(limit: 20)
        }
    }

    private var recentList: some View {
        List {
            if !recentArticles.isEmpty {
                Section("Recently Read") {
                    ForEach(recentArticles) { article in
                        articleRow(article)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Search Wikipedia",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Full-text search across \(appState.corpusArticleCount.formatted()) vital articles")
                )
            }
        }
        .listStyle(.insetGrouped)
    }

    private var resultsList: some View {
        List(results) { article in
            articleRow(article)
        }
        .listStyle(.plain)
    }

    private func articleRow(_ article: Article) -> some View {
        Button {
            localSelection = article
        } label: {
            VStack(alignment: .leading, spacing: 4) {
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
                    Text(cat).font(.caption).foregroundStyle(.blue)
                }
                Text(article.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.clear)
    }
}
