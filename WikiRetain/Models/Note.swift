import Foundation

struct Note: Identifiable, Codable {
    let id: String           // UUID
    let articleId: Int64
    var pageNumber: Int
    var inkData: Data?       // PKDrawing serialised
    var ocrText: String?
    var markdown: String?
    var llmConfidence: Double?
    var factualIssues: [FactualIssue]
    let createdAt: Date
    var updatedAt: Date

    struct FactualIssue: Codable, Identifiable {
        let id: String
        let description: String
        let severity: Severity

        enum Severity: String, Codable {
            case minor, major
        }
    }

    init(articleId: Int64, pageNumber: Int = 1) {
        self.id = UUID().uuidString
        self.articleId = articleId
        self.pageNumber = pageNumber
        self.factualIssues = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Used when loading from DB — preserves the stored UUID
    init(id: String, articleId: Int64, pageNumber: Int, createdAt: Date) {
        self.id = id
        self.articleId = articleId
        self.pageNumber = pageNumber
        self.factualIssues = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}
