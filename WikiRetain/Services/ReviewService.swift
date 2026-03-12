import Foundation
import SQLite3

@MainActor
final class ReviewService: ObservableObject {
    private let db: DatabaseService

    @Published var dueCount: Int = 0

    init(db: DatabaseService) {
        self.db = db
    }

    func refreshDueCount() {
        var count = 0
        db.queryUser("SELECT COUNT(*) FROM srs_cards WHERE due_date <= ?;",
                     bindings: [.double(Date().timeIntervalSince1970)]) { stmt in
            count = DatabaseService.int(stmt, 0)
        }
        dueCount = count
    }

    // MARK: - Schedule new article

    func scheduleNewArticle(articleId: Int64) {
        var existing = false
        db.queryUser("SELECT 1 FROM srs_cards WHERE article_id = ?;",
                     bindings: [.int64(articleId)]) { _ in existing = true }
        guard !existing else { return }

        let card = SRSCard(articleId: articleId)
        upsertCard(card)
    }

    // MARK: - Due queue (interleaved)

    func dueQueue(limit: Int = 50, targetRetention: Double = 0.9) -> [SRSCard] {
        var cards: [SRSCard] = []
        let now = Date().timeIntervalSince1970
        db.queryUser("""
            SELECT article_id, due_date, stability, difficulty, elapsed_days,
                   scheduled_days, reps, lapses, state, last_review, fsrs_params
            FROM srs_cards
            WHERE due_date <= ?
            ORDER BY due_date ASC
            LIMIT ?;
        """, bindings: [.double(now), .int64(Int64(limit))]) { stmt in
            cards.append(self.cardFromStmt(stmt))
        }
        return interleaved(cards: cards)
    }

    // Interleave by category — no two consecutive from same category
    private func interleaved(cards: [SRSCard]) -> [SRSCard] {
        // Fetch categories for these article IDs
        var categoryMap: [Int64: String] = [:]
        for card in cards {
            db.queryCorpus("SELECT category FROM articles WHERE id = ?;",
                           bindings: [.int64(card.articleId)]) { stmt in
                categoryMap[card.articleId] = DatabaseService.optText(stmt, 0) ?? "General"
            }
        }

        var result: [SRSCard] = []
        var remaining = cards
        var lastCategory: String? = nil

        while !remaining.isEmpty {
            let pick = remaining.first { card in
                categoryMap[card.articleId] != lastCategory
            } ?? remaining.first!

            result.append(pick)
            lastCategory = categoryMap[pick.articleId]
            remaining.removeAll { $0.articleId == pick.articleId }
        }
        return result
    }

    // MARK: - Apply rating

    func applyRating(card: SRSCard, rating: RecallRating) {
        let updated = FSRS.schedule(card: card, rating: rating)
        upsertCard(updated)
        refreshDueCount()
    }

    // MARK: - Quiz session persistence

    func saveQuizSession(_ session: QuizSession) {
        let questionsJSON = (try? JSONEncoder().encode(session.questions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let answersJSON = (try? JSONEncoder().encode(session.userAnswers)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let completedTs = session.completedAt?.timeIntervalSince1970 ?? 0

        db.prepareUser("""
            INSERT OR REPLACE INTO quiz_sessions(id, article_id, questions, user_answers, total_score, recall_rating, completed_at)
            VALUES(?,?,?,?,?,?,?);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, session.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, session.articleId)
            sqlite3_bind_text(stmt, 3, questionsJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, answersJSON, -1, SQLITE_TRANSIENT)
            if let score = session.totalScore {
                sqlite3_bind_double(stmt, 5, score)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let rating = session.recallRating {
                sqlite3_bind_int(stmt, 6, Int32(rating.rawValue))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_double(stmt, 7, completedTs)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Stats

    struct ReviewStats {
        var totalReviewed: Int
        var retentionRate: Double
        var streak: Int
        var corpusRetained: Double
    }

    func stats(corpusSize: Int = 50237) -> ReviewStats {
        var reviewed = 0
        db.queryUser("SELECT COUNT(*) FROM quiz_sessions WHERE completed_at IS NOT NULL;") { stmt in
            reviewed = DatabaseService.int(stmt, 0)
        }
        var avgScore = 0.0
        db.queryUser("SELECT AVG(total_score) FROM quiz_sessions WHERE total_score IS NOT NULL;") { stmt in
            avgScore = DatabaseService.double(stmt, 0)
        }
        var readCount = 0
        db.queryUser("SELECT COUNT(*) FROM user_articles WHERE read_at IS NOT NULL;") { stmt in
            readCount = DatabaseService.int(stmt, 0)
        }
        let corpusRetained = corpusSize > 0 ? Double(readCount) / Double(corpusSize) : 0
        return ReviewStats(totalReviewed: reviewed, retentionRate: avgScore,
                           streak: computeStreak(), corpusRetained: corpusRetained)
    }

    private func computeStreak() -> Int {
        var dates: [Date] = []
        db.queryUser("""
            SELECT DATE(completed_at, 'unixepoch') as d
            FROM quiz_sessions
            WHERE completed_at IS NOT NULL
            GROUP BY d
            ORDER BY d DESC
            LIMIT 365;
        """) { stmt in
            if let s = DatabaseService.optText(stmt, 0) {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                if let d = df.date(from: s) { dates.append(d) }
            }
        }

        var streak = 0
        var checkDate = Calendar.current.startOfDay(for: Date())
        for date in dates {
            if Calendar.current.isDate(date, inSameDayAs: checkDate) {
                streak += 1
                checkDate = Calendar.current.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }
        return streak
    }

    // MARK: - Card from DB

    private func cardFromStmt(_ stmt: OpaquePointer) -> SRSCard {
        var card = SRSCard(articleId: DatabaseService.int64(stmt, 0))
        card.dueDate = Date(timeIntervalSince1970: DatabaseService.double(stmt, 1))
        card.stability = DatabaseService.double(stmt, 2)
        card.difficulty = DatabaseService.double(stmt, 3)
        card.elapsedDays = DatabaseService.int(stmt, 4)
        card.scheduledDays = DatabaseService.int(stmt, 5)
        card.reps = DatabaseService.int(stmt, 6)
        card.lapses = DatabaseService.int(stmt, 7)
        card.state = SRSCard.CardState(rawValue: DatabaseService.int(stmt, 8)) ?? .new
        card.lastReview = DatabaseService.date(stmt, 9)
        if let paramsJSON = DatabaseService.optText(stmt, 10),
           let data = paramsJSON.data(using: .utf8),
           let params = try? JSONDecoder().decode(FSRSParams.self, from: data) {
            card.fsrsParams = params
        }
        return card
    }

    private func upsertCard(_ card: SRSCard) {
        let paramsJSON = card.fsrsParams.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        db.prepareUser("""
            INSERT OR REPLACE INTO srs_cards
                (article_id, due_date, stability, difficulty, elapsed_days, scheduled_days,
                 reps, lapses, state, last_review, fsrs_params)
            VALUES(?,?,?,?,?,?,?,?,?,?,?);
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, card.articleId)
            sqlite3_bind_double(stmt, 2, card.dueDate.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, card.stability)
            sqlite3_bind_double(stmt, 4, card.difficulty)
            sqlite3_bind_int(stmt, 5, Int32(card.elapsedDays))
            sqlite3_bind_int(stmt, 6, Int32(card.scheduledDays))
            sqlite3_bind_int(stmt, 7, Int32(card.reps))
            sqlite3_bind_int(stmt, 8, Int32(card.lapses))
            sqlite3_bind_int(stmt, 9, Int32(card.state.rawValue))
            if let lr = card.lastReview {
                sqlite3_bind_double(stmt, 10, lr.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            if let p = paramsJSON {
                sqlite3_bind_text(stmt, 11, p, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            sqlite3_step(stmt)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
