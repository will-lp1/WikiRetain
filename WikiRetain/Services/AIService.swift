import Foundation
import FoundationModels

/// Wraps Apple Foundation Models (iOS 26+) for all LLM features.
@MainActor
final class AIService: ObservableObject {
    @Published var isAvailable = false

    private var session: LanguageModelSession?

    var unavailableReason: SystemLanguageModel.Availability.UnavailableReason?

    func checkAvailability() async -> Bool {
        // Foundation Models assets don't exist in the simulator — skip entirely.
        #if targetEnvironment(simulator)
        isAvailable = false
        return false
        #else
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            isAvailable = true
            unavailableReason = nil
            session = LanguageModelSession()
            return true
        case .unavailable(let reason):
            isAvailable = false
            unavailableReason = reason
            return false
        default:
            isAvailable = false
            return false
        }
        #endif
    }

    var unavailableDescription: String {
        switch unavailableReason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled. Turn it on in Settings → Apple Intelligence."
        case .modelNotReady:
            return "Apple Intelligence is downloading. Try again in a few minutes."
        case nil:
            return "Apple Intelligence is not available."
        default:
            return "Apple Intelligence is not available on this device or configuration."
        }
    }

    // MARK: - Note Processing

    @Generable
    struct NoteResult {
        @Guide(description: "OCR text corrected for spelling and clarity")
        var correctedText: String
        @Guide(description: "Markdown-formatted version of the note")
        var markdown: String
        @Guide(description: "Confidence score 0.0–1.0")
        var confidence: Double
        @Guide(description: "List of factual issues found comparing note to article")
        var factualIssues: [String]
    }

    func processNote(ocrText: String, articleTitle: String, articleExcerpt: String) async throws -> NoteResult {
        guard let session else { throw AIError.notAvailable }
        let prompt = """
        You are validating a handwritten note about the Wikipedia article "\(articleTitle)".

        Article excerpt:
        \(articleExcerpt.prefix(1500))

        Raw OCR text from the note:
        \(ocrText)

        Correct the OCR text, convert it to clean Markdown, rate your confidence 0.0–1.0,
        and list any factual inconsistencies with the article.
        """
        return try await session.respond(to: prompt, generating: NoteResult.self).content
    }

    // MARK: - Quiz Generation

    @Generable
    struct GeneratedQuiz {
        @Guide(description: "3–5 quiz questions about the article")
        var questions: [GeneratedQuestion]
        @Guide(description: "Overall difficulty 1–5")
        var difficulty: Int
    }

    @Generable
    struct GeneratedQuestion {
        @Guide(description: "Question type: factual, elaborative, cross_linking, or application")
        var type: String
        @Guide(description: "The question text")
        var question: String
        @Guide(description: "The expected correct answer")
        var expectedAnswer: String
    }

    func generateQuiz(article: String, title: String, notes: String?, relatedArticle: String?) async throws -> GeneratedQuiz {
        guard let session else { throw AIError.notAvailable }
        var prompt = """
        Generate a quiz for the Wikipedia article "\(title)".

        Article text:
        \(article.prefix(3000))
        """
        if let notes, !notes.isEmpty {
            prompt += "\n\nUser's notes about this article:\n\(notes)"
        }
        if let related = relatedArticle {
            prompt += "\n\nRelated article the user has also read:\n\(related.prefix(500))"
        }
        prompt += """

        Generate exactly:
        - 1 factual question (type: "factual")
        - 2 elaborative questions asking why/how (type: "elaborative")
        - 1 application question (type: "application")
        \(relatedArticle != nil ? "- 1 cross-linking question connecting both articles (type: \"cross_linking\")" : "")

        Questions must be specific to the article content. Never reuse questions from previous sessions.
        """
        return try await session.respond(to: prompt, generating: GeneratedQuiz.self).content
    }

    // MARK: - Answer Evaluation

    @Generable
    struct AnswerScore {
        @Guide(description: "Whether the answer is essentially correct")
        var correct: Bool
        @Guide(description: "Score 0.0–1.0")
        var points: Double
        @Guide(description: "Brief feedback explaining the score")
        var feedback: String
    }

    func evaluateAnswer(question: String, expectedAnswer: String, userAnswer: String, articleContext: String) async throws -> AnswerScore {
        guard let session else { throw AIError.notAvailable }
        let prompt = """
        Evaluate this quiz answer about a Wikipedia article.

        Question: \(question)
        Expected answer: \(expectedAnswer)
        User's answer: \(userAnswer)

        Article context: \(articleContext.prefix(1000))

        Score the answer 0.0–1.0. Be lenient on phrasing but strict on factual accuracy.
        Give brief feedback (1–2 sentences).
        """
        return try await session.respond(to: prompt, generating: AnswerScore.self).content
    }

    // MARK: - Node Summary

    func generateNodeSummary(articleTitle: String, articleExcerpt: String) async throws -> String {
        guard let session else { throw AIError.notAvailable }
        let prompt = """
        Write exactly 3 sentences summarising the Wikipedia article "\(articleTitle)".
        Be concise and factual. Article excerpt: \(articleExcerpt.prefix(1000))
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }

    /// Streaming variant — yields partial strings as they're generated.
    func streamNodeSummary(articleTitle: String, articleExcerpt: String) throws -> LanguageModelSession.ResponseStream<String> {
        guard let session else { throw AIError.notAvailable }
        let prompt = """
        Write exactly 3 sentences summarising the Wikipedia article "\(articleTitle)".
        Be concise and factual. Article excerpt: \(articleExcerpt.prefix(1000))
        """
        return session.streamResponse(to: prompt, generating: String.self)
    }

    // MARK: - Semantic Re-ranking

    @Generable
    struct RankedList {
        @Guide(description: "Indices of the titles ordered by relevance to the query, most relevant first")
        var rankedIndices: [Int]
    }

    func rerankResults(query: String, titles: [String]) async throws -> [Int] {
        guard let session else { throw AIError.notAvailable }

        let titlesText = titles.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Re-rank these Wikipedia article titles by relevance to the query: "\(query)"

        Articles:
        \(titlesText)

        Return the indices from most to least relevant.
        """
        let response = try await session.respond(to: prompt, generating: RankedList.self)
        return response.content.rankedIndices
    }

    enum AIError: Error, LocalizedError {
        case notAvailable

        var errorDescription: String? {
            "Apple Intelligence is not available. Enable it in Settings → Apple Intelligence."
        }
    }
}
