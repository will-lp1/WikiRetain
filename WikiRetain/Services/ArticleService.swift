import Foundation
import SQLite3

@MainActor
final class ArticleService: ObservableObject {
    private let db: DatabaseService

    init(db: DatabaseService) {
        self.db = db
    }

    func hasCorpus() async -> Bool {
        db.corpusArticleCount > 0
    }

    // MARK: - Search

    func search(query: String, limit: Int = 50) async -> [Article] {
        guard !query.isEmpty else { return [] }
        var results: [Article] = []
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT a.id, a.title, a.body_html, a.category, a.wikilinks, a.word_count, a.vital_level
            FROM articles_fts
            JOIN articles a ON articles_fts.rowid = a.id
            WHERE articles_fts MATCH '\(escaped)*'
            ORDER BY rank
            LIMIT \(limit);
        """
        db.queryCorpus(sql) { stmt in
            results.append(self.articleFromStmt(stmt))
        }
        return applyUserState(to: results)
    }

    func article(id: Int64) async -> Article? {
        var result: Article?
        db.queryCorpus("""
            SELECT id, title, body_html, category, wikilinks, word_count, vital_level
            FROM articles WHERE id = ?;
        """, bindings: [.int64(id)]) { stmt in
            result = self.articleFromStmt(stmt)
        }
        guard let a = result else { return nil }
        return applyUserState(to: [a]).first
    }

    func articles(ids: [Int64]) async -> [Article] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var results: [Article] = []
        db.queryCorpus("""
            SELECT id, title, body_html, category, wikilinks, word_count, vital_level
            FROM articles WHERE id IN (\(placeholders));
        """, bindings: ids.map { .int64($0) }) { stmt in
            results.append(self.articleFromStmt(stmt))
        }
        return applyUserState(to: results)
    }

    func recentlyRead(limit: Int = 20) async -> [Article] {
        // Get ordered IDs from userDB, then fetch articles from corpusDB
        var orderedIds: [Int64] = []
        db.queryUser("""
            SELECT article_id FROM user_articles
            WHERE read_at IS NOT NULL
            ORDER BY read_at DESC LIMIT ?;
        """, bindings: [.int64(Int64(limit))]) { stmt in
            orderedIds.append(DatabaseService.int64(stmt, 0))
        }
        guard !orderedIds.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: (await articles(ids: orderedIds)).map { ($0.id, $0) })
        return orderedIds.compactMap { byId[$0] }
    }

    // MARK: - Mark as Read

    func markAsRead(_ articleId: Int64) async {
        let now = Date().timeIntervalSince1970
        db.prepareUser("""
            INSERT INTO user_articles(article_id, read_at, read_count)
            VALUES(?,?,1)
            ON CONFLICT(article_id) DO UPDATE SET
                read_at = excluded.read_at,
                read_count = read_count + 1;
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, articleId)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_step(stmt)
        }

        db.prepareUser("""
            INSERT OR IGNORE INTO graph_nodes(article_id, first_visited) VALUES(?,?);
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, articleId)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_step(stmt)
        }

        db.prepareUser("""
            INSERT INTO reading_history(article_id, visited_at) VALUES(?,?);
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, articleId)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_step(stmt)
        }
    }

    func markAsUnread(_ articleId: Int64) async {
        db.prepareUser("""
            UPDATE user_articles SET read_at = NULL WHERE article_id = ?;
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, articleId)
            sqlite3_step(stmt)
        }
    }

    func saveScrollPosition(_ articleId: Int64, fraction: Double) async {
        db.prepareUser("""
            INSERT INTO user_articles(article_id, last_scroll_frac)
            VALUES(?,?)
            ON CONFLICT(article_id) DO UPDATE SET last_scroll_frac = excluded.last_scroll_frac;
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, articleId)
            sqlite3_bind_double(stmt, 2, fraction)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Wikilinks

    func wikilinks(for article: Article) async -> [Article] {
        guard !article.wikilinks.isEmpty else { return [] }
        return await articles(ids: article.wikilinks)
    }

    // MARK: - Navigation Edge

    func recordNavigation(from fromId: Int64, to toId: Int64) async {
        let now = Date().timeIntervalSince1970
        db.prepareUser("""
            INSERT OR IGNORE INTO graph_edges(from_id, to_id, edge_type, created_at)
            VALUES(?,?,'navigation',?);
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, fromId)
            sqlite3_bind_int64(stmt, 2, toId)
            sqlite3_bind_double(stmt, 3, now)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Stats

    var readCount: Int {
        var count = 0
        db.queryUser("SELECT COUNT(*) FROM user_articles WHERE read_at IS NOT NULL;") { stmt in
            count = DatabaseService.int(stmt, 0)
        }
        return count
    }

    // MARK: - Private Helpers

    /// Fetch user state for a batch of articles in one userDB query and apply it.
    private func applyUserState(to articles: [Article]) -> [Article] {
        guard !articles.isEmpty else { return articles }
        let ids = articles.map { $0.id }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var userState: [Int64: (readAt: Date?, readCount: Int, scrollFrac: Double, isSaved: Bool)] = [:]
        db.queryUser("""
            SELECT article_id, read_at, read_count, last_scroll_frac, is_saved
            FROM user_articles WHERE article_id IN (\(placeholders));
        """, bindings: ids.map { .int64($0) }) { stmt in
            let aid = DatabaseService.int64(stmt, 0)
            let readAt = DatabaseService.date(stmt, 1)
            let readCount = DatabaseService.int(stmt, 2)
            let scrollFrac = DatabaseService.double(stmt, 3)
            let isSaved = DatabaseService.int(stmt, 4) != 0
            userState[aid] = (readAt, readCount, scrollFrac, isSaved)
        }
        return articles.map { a in
            var a = a
            if let s = userState[a.id] {
                a.readAt = s.readAt
                a.readCount = s.readCount
                a.lastScrollFrac = s.scrollFrac
                a.isSaved = s.isSaved
            }
            return a
        }
    }

    private func articleFromStmt(_ stmt: OpaquePointer) -> Article {
        let id = DatabaseService.int64(stmt, 0)
        let title = DatabaseService.text(stmt, 1)
        let html = DatabaseService.text(stmt, 2)
        let category = DatabaseService.optText(stmt, 3)
        let wikilinkJSON = DatabaseService.optText(stmt, 4) ?? "[]"
        let wordCount = DatabaseService.int(stmt, 5)
        let vitalLevel = DatabaseService.int(stmt, 6)

        let wikilinks = (try? JSONDecoder().decode([Int64].self,
            from: wikilinkJSON.data(using: .utf8) ?? Data())) ?? []

        return Article(id: id, title: title, bodyHTML: html, category: category,
                       wikilinks: wikilinks, wordCount: wordCount, vitalLevel: vitalLevel)
    }
}
