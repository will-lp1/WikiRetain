import Foundation

struct Article: Identifiable, Hashable, Codable {
    let id: Int64
    let title: String
    let bodyHTML: String
    let category: String?
    let wikilinks: [Int64]
    let wordCount: Int
    let vitalLevel: Int

    // User state (optional, from JOIN)
    var readAt: Date?
    var readCount: Int = 0
    var lastScrollFrac: Double = 0.0
    var isSaved: Bool = false

    var isRead: Bool { readAt != nil }

    var snippet: String {
        let stripped = bodyHTML
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(200))
    }
}

struct ArticleSearchResult: Identifiable {
    let article: Article
    let rank: Double
    var id: Int64 { article.id }
}

struct WikiLink: Identifiable {
    let id: Int64
    let title: String
}
