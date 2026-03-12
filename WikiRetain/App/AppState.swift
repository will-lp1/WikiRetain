import SwiftUI
import Observation

@MainActor
final class AppState: ObservableObject {
    @Published var isInitialized = false
    @Published var hasCorpus = false
    @Published var aiAvailable = false
    @Published var selectedTab: Tab = .home
    @Published var corpusArticleCount: Int = 0

    var corpusResourceRequest: NSBundleResourceRequest? // nil when using URL/file import

    let db: DatabaseService
    let articleService: ArticleService
    let noteService: NoteService
    let reviewService: ReviewService
    let graphService: GraphService
    let ocrService: OCRService
    let aiService: AIService

    enum Tab: Hashable {
        case home, search, review, mindMap, settings
    }

    init() {
        let db = DatabaseService()
        self.db = db
        self.articleService = ArticleService(db: db)
        self.noteService = NoteService(db: db)
        self.reviewService = ReviewService(db: db)
        self.graphService = GraphService(db: db)
        self.ocrService = OCRService()
        self.aiService = AIService()
    }

    func initialize() async {
        await db.setup()
        corpusArticleCount = db.corpusArticleCount
        hasCorpus = corpusArticleCount > 0
        aiAvailable = await aiService.checkAvailability()
        isInitialized = true
    }
}
