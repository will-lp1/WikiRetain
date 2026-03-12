import Foundation
import SQLite3

@MainActor
final class NoteService: ObservableObject {
    private let db: DatabaseService

    init(db: DatabaseService) {
        self.db = db
    }

    func notes(for articleId: Int64) -> [Note] {
        var results: [Note] = []
        db.queryUser("""
            SELECT id, article_id, page_number, ink_data, ocr_text, markdown,
                   llm_confidence, factual_issues, created_at, updated_at
            FROM notes
            WHERE article_id = ?
            ORDER BY page_number, created_at;
        """, bindings: [.int64(articleId)]) { stmt in
            results.append(self.noteFromStmt(stmt))
        }
        return results
    }

    func save(_ note: Note) {
        let issuesJSON = (try? JSONEncoder().encode(note.factualIssues)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        db.prepareUser("""
            INSERT OR REPLACE INTO notes
                (id, article_id, page_number, ink_data, ocr_text, markdown,
                 llm_confidence, factual_issues, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, note.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, note.articleId)
            sqlite3_bind_int(stmt, 3, Int32(note.pageNumber))
            if let ink = note.inkData {
                ink.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(ink.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            self.bindOptText(stmt, 5, note.ocrText)
            self.bindOptText(stmt, 6, note.markdown)
            if let c = note.llmConfidence { sqlite3_bind_double(stmt, 7, c) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, issuesJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 9, note.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 10, note.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func delete(_ noteId: String) {
        db.prepareUser("DELETE FROM notes WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, noteId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func hasNotes(articleId: Int64) -> Bool {
        var result = false
        db.queryUser("SELECT 1 FROM notes WHERE article_id = ? LIMIT 1;",
                     bindings: [.int64(articleId)]) { _ in result = true }
        return result
    }

    // MARK: - Parsing

    private func noteFromStmt(_ stmt: OpaquePointer) -> Note {
        let issuesJSON = DatabaseService.optText(stmt, 7) ?? "[]"
        let issues = (try? JSONDecoder().decode(
            [Note.FactualIssue].self,
            from: Data(issuesJSON.utf8)
        )) ?? []

        let id        = DatabaseService.text(stmt, 0)
        let articleId = DatabaseService.int64(stmt, 1)
        let pageNum   = DatabaseService.int(stmt, 2)
        let createdAt = Date(timeIntervalSince1970: DatabaseService.double(stmt, 8))

        var note = Note(id: id, articleId: articleId, pageNumber: pageNum, createdAt: createdAt)
        note.inkData       = DatabaseService.blob(stmt, 3)
        note.ocrText       = DatabaseService.optText(stmt, 4)
        note.markdown      = DatabaseService.optText(stmt, 5)
        note.llmConfidence = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? DatabaseService.double(stmt, 6) : nil
        note.factualIssues = issues
        note.updatedAt     = Date(timeIntervalSince1970: DatabaseService.double(stmt, 9))
        return note
    }

    private func bindOptText(_ stmt: OpaquePointer, _ col: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, col, v, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, col)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
