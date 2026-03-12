import Foundation

struct QuizSession: Identifiable, Codable {
    let id: String
    let articleId: Int64
    var questions: [QuizQuestion]
    var userAnswers: [UserAnswer]
    var totalScore: Double?
    var recallRating: RecallRating?
    var completedAt: Date?

    var isComplete: Bool { completedAt != nil }

    init(articleId: Int64, questions: [QuizQuestion]) {
        self.id = UUID().uuidString
        self.articleId = articleId
        self.questions = questions
        self.userAnswers = []
    }
}

struct QuizQuestion: Identifiable, Codable {
    let id: String
    let type: QuestionType
    let question: String
    let expectedAnswer: String
    let relatedArticleId: Int64?   // for cross-linking questions

    init(type: QuestionType, question: String, expectedAnswer: String, relatedArticleId: Int64? = nil) {
        self.id = UUID().uuidString
        self.type = type
        self.question = question
        self.expectedAnswer = expectedAnswer
        self.relatedArticleId = relatedArticleId
    }

    enum QuestionType: String, Codable, CaseIterable {
        case factual
        case elaborative
        case crossLinking = "cross_linking"
        case application

        var label: String {
            switch self {
            case .factual: "Factual"
            case .elaborative: "Elaborative"
            case .crossLinking: "Cross-linking"
            case .application: "Application"
            }
        }

        var cognitiveLoad: Int {
            switch self {
            case .factual: 1
            case .elaborative: 2
            case .crossLinking: 3
            case .application: 4
            }
        }
    }
}

struct UserAnswer: Identifiable, Codable {
    let id: String
    let questionId: String
    var answer: String
    var score: Double?         // 0.0–1.0
    var feedback: String?
    var isCorrect: Bool { (score ?? 0) >= 0.7 }

    init(questionId: String, answer: String) {
        self.id = UUID().uuidString
        self.questionId = questionId
        self.answer = answer
    }
}
