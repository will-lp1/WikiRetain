import SwiftUI

struct ReviewSessionView: View {
    @EnvironmentObject var appState: AppState
    let cards: [SRSCard]
    @Binding var currentIndex: Int
    let onComplete: () -> Void

    @State private var currentArticle: Article?
    @State private var currentSession: QuizSession?
    @State private var phase: Phase = .generatingQuiz
    @State private var currentAnswers: [String: String] = [:]
    @State private var evaluatedSession: QuizSession?
    @State private var showArticle = false

    enum Phase {
        case generatingQuiz
        case quiz
        case evaluating
        case results
        case rating
        case articleReview
    }

    var currentCard: SRSCard { cards[currentIndex] }
    var progress: Double { Double(currentIndex) / Double(cards.count) }

    var body: some View {
        VStack(spacing: 0) {
            // Progress
            ProgressView(value: progress)
                .tint(.orange)
                .padding(.horizontal)
                .padding(.top, 8)

            Text("\(currentIndex + 1) of \(cards.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Divider()

            switch phase {
            case .generatingQuiz:
                GeneratingView(title: currentArticle?.title)
                    .task { await prepareSession() }

            case .quiz:
                if let session = currentSession, let article = currentArticle {
                    QuizView(session: session, article: article, answers: $currentAnswers,
                             onSubmit: { submitAnswers() })
                }

            case .evaluating:
                GeneratingView(title: "Evaluating your answers…")

            case .results:
                if let session = evaluatedSession, let article = currentArticle {
                    ResultsView(session: session, article: article, onRate: { phase = .rating })
                }

            case .rating:
                if let article = currentArticle {
                    RatingView(article: article, card: currentCard) { rating in
                        applyRating(rating)
                    }
                }

            case .articleReview:
                if let article = currentArticle {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Optional Re-read")
                                .font(.headline)
                            Spacer()
                            Button("Skip") { advance() }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Next") { advance() }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        Divider()
                        ArticleWebView(article: article, wikilinks: [],
                                       onLinkTap: { _ in }, onLinkLongPress: { _ in },
                                       onScrollProgress: { _ in },
                                       onScrolledToEnd: {})
                    }
                }
            }
        }
    }

    // MARK: - Flow

    private func prepareSession() async {
        currentArticle = await appState.articleService.article(id: currentCard.articleId)
        guard let article = currentArticle else {
            advance()
            return
        }

        guard appState.aiAvailable else {
            // Fallback: generic questions without AI
            let fallback = fallbackQuiz(for: article)
            currentSession = QuizSession(articleId: article.id, questions: fallback)
            phase = .quiz
            return
        }

        do {
            let notes = appState.noteService.notes(for: article.id)
                .compactMap { $0.markdown }
                .joined(separator: "\n\n")

            let generated = try await appState.aiService.generateQuiz(
                article: article.bodyHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                title: article.title,
                notes: notes.isEmpty ? nil : notes,
                relatedArticle: nil
            )

            let questions = generated.questions.map { q in
                QuizQuestion(
                    type: QuizQuestion.QuestionType(rawValue: q.type) ?? .factual,
                    question: q.question,
                    expectedAnswer: q.expectedAnswer
                )
            }
            currentSession = QuizSession(articleId: article.id, questions: questions)
            phase = .quiz
        } catch {
            let fallback = fallbackQuiz(for: article)
            currentSession = QuizSession(articleId: article.id, questions: fallback)
            phase = .quiz
        }
    }

    private func submitAnswers() {
        guard var session = currentSession, let article = currentArticle else { return }
        phase = .evaluating

        Task {
            var answers: [UserAnswer] = []

            for question in session.questions {
                let userAnswerText = currentAnswers[question.id] ?? ""
                var answer = UserAnswer(questionId: question.id, answer: userAnswerText)

                if appState.aiAvailable && !userAnswerText.isEmpty {
                    if let scored = try? await appState.aiService.evaluateAnswer(
                        question: question.question,
                        expectedAnswer: question.expectedAnswer,
                        userAnswer: userAnswerText,
                        articleContext: String(article.bodyHTML.prefix(1000))
                    ) {
                        answer.score = scored.points
                        answer.feedback = scored.feedback
                    }
                } else {
                    // Simple heuristic: non-empty = 0.5
                    answer.score = userAnswerText.isEmpty ? 0 : 0.5
                    answer.feedback = userAnswerText.isEmpty ? "No answer provided." : "Self-grade this answer."
                }
                answers.append(answer)
            }

            session.userAnswers = answers
            session.totalScore = answers.compactMap { $0.score }.reduce(0, +) / Double(max(answers.count, 1))

            evaluatedSession = session
            appState.reviewService.saveQuizSession(session)
            phase = .results
        }
    }

    private func applyRating(_ rating: RecallRating) {
        appState.reviewService.applyRating(card: currentCard, rating: rating)
        phase = .articleReview
    }

    private func advance() {
        if currentIndex < cards.count - 1 {
            currentIndex += 1
            currentArticle = nil
            currentSession = nil
            evaluatedSession = nil
            currentAnswers = [:]
            phase = .generatingQuiz
        } else {
            onComplete()
        }
    }

    private func fallbackQuiz(for article: Article) -> [QuizQuestion] {
        [
            QuizQuestion(type: .factual,
                         question: "What is the main subject of \"\(article.title)\"?",
                         expectedAnswer: article.title),
            QuizQuestion(type: .elaborative,
                         question: "Why is \"\(article.title)\" significant?",
                         expectedAnswer: "Varies — self-grade."),
            QuizQuestion(type: .application,
                         question: "How would you explain \"\(article.title)\" to someone unfamiliar?",
                         expectedAnswer: "Varies — self-grade.")
        ]
    }
}

// MARK: - Generating View

private struct GeneratingView: View {
    let title: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            if let title {
                Text("Generating quiz for\n\"\(title)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Preparing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Quiz View

private struct QuizView: View {
    let session: QuizSession
    let article: Article
    @Binding var answers: [String: String]
    let onSubmit: () -> Void
    @FocusState private var focusedQuestion: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(article.title)
                    .font(.title2.bold())
                    .padding(.horizontal)

                Text("Answer before reading the article — this is the testing effect at work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ForEach(Array(session.questions.enumerated()), id: \.element.id) { idx, question in
                    QuestionCard(index: idx + 1, question: question,
                                 answer: Binding(
                                    get: { answers[question.id] ?? "" },
                                    set: { answers[question.id] = $0 }
                                 ),
                                 isFocused: focusedQuestion == question.id)
                    .onTapGesture { focusedQuestion = question.id }
                }

                Button(action: onSubmit) {
                    Text("Submit Answers")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .padding(.top)
        }
    }
}

private struct QuestionCard: View {
    let index: Int
    let question: QuizQuestion
    @Binding var answer: String
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Q\(index)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(typeColor)
                    .clipShape(Capsule())
                Text(question.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.body.bold())
            TextField("Your answer…", text: $answer, axis: .vertical)
                .lineLimit(3...6)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    var typeColor: Color {
        switch question.type {
        case .factual: .gray
        case .elaborative: .blue
        case .crossLinking: .purple
        case .application: .orange
        }
    }
}

// MARK: - Results View

private struct ResultsView: View {
    let session: QuizSession
    let article: Article
    let onRate: () -> Void

    var totalScore: Double { session.totalScore ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Score header
                VStack(spacing: 8) {
                    Text("\(Int(totalScore * 100))%")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(scoreColor)
                    Text(scoreLabel)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)

                Divider()

                // Per-question feedback
                ForEach(Array(session.questions.enumerated()), id: \.element.id) { idx, question in
                    if let answer = session.userAnswers.first(where: { $0.questionId == question.id }) {
                        FeedbackCard(question: question, answer: answer)
                    }
                }

                Button(action: onRate) {
                    Text("Rate Your Recall")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }

    var scoreColor: Color {
        switch totalScore {
        case 0.8...: .green
        case 0.6..<0.8: .orange
        default: .red
        }
    }

    var scoreLabel: String {
        switch totalScore {
        case 0.8...: "Excellent recall"
        case 0.6..<0.8: "Good progress"
        case 0.4..<0.6: "Keep practising"
        default: "Needs review"
        }
    }
}

private struct FeedbackCard: View {
    let question: QuizQuestion
    let answer: UserAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.subheadline.bold())
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: answer.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(answer.isCorrect ? .green : .red)
                Text(answer.answer.isEmpty ? "(no answer)" : answer.answer)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if let feedback = answer.feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if let score = answer.score {
                ProgressView(value: score)
                    .tint(answer.isCorrect ? .green : .orange)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

// MARK: - Rating View

private struct RatingView: View {
    @EnvironmentObject var appState: AppState
    let article: Article
    let card: SRSCard
    let onRate: (RecallRating) -> Void

    var intervals: [RecallRating: Int] { FSRS.previewIntervals(card: card) }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("How well did you recall\n\"\(article.title)\"?")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Your rating adjusts when this article surfaces again.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(RecallRating.allCases, id: \.self) { rating in
                    Button {
                        onRate(rating)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rating.label)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(rating.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let days = intervals[rating] {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(days == 1 ? "Tomorrow" : "\(days)d")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(ratingBackground(rating))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    func ratingBackground(_ rating: RecallRating) -> Color {
        switch rating {
        case .again: .red.opacity(0.15)
        case .hard: .orange.opacity(0.15)
        case .good: .green.opacity(0.15)
        case .easy: .blue.opacity(0.15)
        }
    }
}
