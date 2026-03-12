import Foundation
import SQLite3

final class DatabaseService: @unchecked Sendable {
    private var corpusDB: OpaquePointer?
    private var userDB: OpaquePointer?

    private let corpusPath: String
    private let userDBPath: String

    init() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bundlePath = Bundle.main.path(forResource: "corpus", ofType: "db")
        self.corpusPath = bundlePath ?? docsDir.appendingPathComponent("corpus.db").path
        self.userDBPath = docsDir.appendingPathComponent("userdata.db").path
    }

    func setup() async {
        openCorpus()
        openUserDB()
        createUserTables()
    }

    // MARK: - Open DBs

    private func openCorpus() {
        let roFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX

        // 1. Try the bundled corpus (read-only, fastest)
        if sqlite3_open_v2(corpusPath, &corpusDB, roFlags, nil) == SQLITE_OK {
            return
        }

        // 2. Try Documents/corpus.db (user-downloaded via install_corpus.sh)
        let docsCorpus = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("corpus.db").path
        if sqlite3_open_v2(docsCorpus, &corpusDB, roFlags, nil) == SQLITE_OK {
            return
        }

        // 3. Dev fallback: create in-memory sample corpus
        let rwFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let devPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("corpus_dev.db").path
        if sqlite3_open_v2(devPath, &corpusDB, rwFlags, nil) == SQLITE_OK {
            createDevCorpus()
        }
    }

    private func openUserDB() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(userDBPath, &userDB, flags, nil) == SQLITE_OK else {
            print("Failed to open user DB")
            return
        }
        exec(userDB, "PRAGMA journal_mode=WAL;")
        exec(userDB, "PRAGMA foreign_keys=ON;")
    }

    // MARK: - Schema

    private func createUserTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS user_articles (
            article_id       INTEGER PRIMARY KEY,
            read_at          REAL,
            read_count       INTEGER DEFAULT 0,
            last_scroll_frac REAL    DEFAULT 0.0,
            is_saved         INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS notes (
            id              TEXT    PRIMARY KEY,
            article_id      INTEGER,
            page_number     INTEGER DEFAULT 1,
            ink_data        BLOB,
            ocr_text        TEXT,
            markdown        TEXT,
            llm_confidence  REAL,
            factual_issues  TEXT,
            created_at      REAL,
            updated_at      REAL
        );

        CREATE TABLE IF NOT EXISTS srs_cards (
            article_id      INTEGER PRIMARY KEY,
            due_date        REAL    NOT NULL,
            stability       REAL,
            difficulty      REAL,
            elapsed_days    INTEGER,
            scheduled_days  INTEGER,
            reps            INTEGER DEFAULT 0,
            lapses          INTEGER DEFAULT 0,
            state           INTEGER DEFAULT 0,
            last_review     REAL,
            fsrs_params     TEXT
        );

        CREATE TABLE IF NOT EXISTS quiz_sessions (
            id              TEXT    PRIMARY KEY,
            article_id      INTEGER,
            questions       TEXT    NOT NULL,
            user_answers    TEXT,
            total_score     REAL,
            recall_rating   INTEGER,
            completed_at    REAL
        );

        CREATE TABLE IF NOT EXISTS graph_nodes (
            article_id      INTEGER PRIMARY KEY,
            first_visited   REAL,
            cluster_id      TEXT,
            summary_cache   TEXT
        );

        CREATE TABLE IF NOT EXISTS graph_edges (
            from_id         INTEGER,
            to_id           INTEGER,
            edge_type       TEXT,
            created_at      REAL,
            PRIMARY KEY (from_id, to_id, edge_type)
        );

        CREATE TABLE IF NOT EXISTS reading_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            article_id      INTEGER,
            visited_at      REAL
        );

        CREATE INDEX IF NOT EXISTS idx_srs_due ON srs_cards(due_date);
        CREATE INDEX IF NOT EXISTS idx_notes_article ON notes(article_id);
        CREATE INDEX IF NOT EXISTS idx_history_article ON reading_history(article_id);
        """
        exec(userDB, sql)
    }

    private func createDevCorpus() {
        // Sample corpus for development — replaced by real corpus.db at ship time
        exec(corpusDB, """
        CREATE TABLE IF NOT EXISTS articles (
            id          INTEGER PRIMARY KEY,
            title       TEXT    NOT NULL,
            body_html   TEXT    NOT NULL,
            category    TEXT,
            wikilinks   TEXT,
            word_count  INTEGER,
            vital_level INTEGER
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
            title, body_text,
            content='articles', content_rowid='id'
        );
        """)
        insertSampleArticles()
    }

    private func insertSampleArticles() {
        let samples: [(Int64, String, String, String)] = [
            (1, "Quantum mechanics", "<p>Quantum mechanics is a fundamental theory in physics...</p>", "Physics"),
            (2, "Wave function", "<p>A wave function describes the quantum state of a system...</p>", "Physics"),
            (3, "Schrödinger equation", "<p>The Schrödinger equation is a linear partial differential equation...</p>", "Physics"),
            (4, "Special relativity", "<p>Special relativity is a theory of the structure of spacetime...</p>", "Physics"),
            (5, "Natural selection", "<p>Natural selection is the differential survival and reproduction...</p>", "Biology"),
            (6, "DNA", "<p>Deoxyribonucleic acid is a polymer composed of two polynucleotide chains...</p>", "Biology"),
            (7, "World War II", "<p>World War II was a global conflict that lasted from 1939 to 1945...</p>", "History"),
            (8, "French Revolution", "<p>The French Revolution was a period of radical political transformation...</p>", "History"),
            (9, "Calculus", "<p>Calculus is the mathematical study of continuous change...</p>", "Mathematics"),
            (10, "Prime number", "<p>A prime number is a natural number greater than 1 that cannot be formed by multiplying two smaller natural numbers...</p>", "Mathematics"),
        ]

        for (id, title, html, category) in samples {
            let wikilinks = "[]"
            let bodyText = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            exec(corpusDB, """
                INSERT OR IGNORE INTO articles(id,title,body_html,category,wikilinks,word_count,vital_level)
                VALUES(\(id),'\(title)','\(html)','\(category)','\(wikilinks)',\(bodyText.split(separator: " ").count),5);
                INSERT OR IGNORE INTO articles_fts(rowid,title,body_text) VALUES(\(id),'\(title)','\(bodyText)');
            """)
        }
    }

    // MARK: - Query Helpers

    func queryCorpus(_ sql: String, bindings: [SQLiteValue] = [], map: (OpaquePointer) -> Void) {
        query(corpusDB, sql, bindings: bindings, map: map)
    }

    func queryUser(_ sql: String, bindings: [SQLiteValue] = [], map: (OpaquePointer) -> Void) {
        query(userDB, sql, bindings: bindings, map: map)
    }

    func execUser(_ sql: String) {
        exec(userDB, sql)
    }

    func prepareUser(_ sql: String, execute: (OpaquePointer) -> Void) {
        prepare(userDB, sql, execute: execute)
    }

    func prepareCorpus(_ sql: String, execute: (OpaquePointer) -> Void) {
        prepare(corpusDB, sql, execute: execute)
    }

    private func query(_ db: OpaquePointer?, _ sql: String, bindings: [SQLiteValue], map: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, val) in bindings.enumerated() {
            val.bind(to: stmt, at: Int32(i + 1))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            map(stmt!)
        }
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String, execute: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        execute(stmt!)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // Convenience column extractors
    static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        String(cString: sqlite3_column_text(stmt, col))
    }

    static func optText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    static func int64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 {
        sqlite3_column_int64(stmt, col)
    }

    static func int(_ stmt: OpaquePointer, _ col: Int32) -> Int {
        Int(sqlite3_column_int(stmt, col))
    }

    static func double(_ stmt: OpaquePointer, _ col: Int32) -> Double {
        sqlite3_column_double(stmt, col)
    }

    static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        let count = sqlite3_column_bytes(stmt, col)
        return Data(bytes: ptr, count: Int(count))
    }

    static func date(_ stmt: OpaquePointer, _ col: Int32) -> Date? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let ts = sqlite3_column_double(stmt, col)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    // MARK: - Corpus Import

    enum ImportError: LocalizedError {
        case accessDenied
        case copyFailed(Error)
        var errorDescription: String? {
            switch self {
            case .accessDenied:      return "Could not access the selected file."
            case .copyFailed(let e): return "Copy failed: \(e.localizedDescription)"
            }
        }
    }

    /// Download corpus.db from a remote URL with progress callbacks, then reopen.
    func downloadCorpus(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stableURL = docsURL.appendingPathComponent("corpus_download_tmp.db")
        let destURL  = docsURL.appendingPathComponent("corpus.db")

        var sessionTask: URLSessionDownloadTask?

        let tempURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { tmpURL, _, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let tmpURL else { cont.resume(throwing: URLError(.badServerResponse)); return }
                    do {
                        try? FileManager.default.removeItem(at: stableURL)
                        try FileManager.default.moveItem(at: tmpURL, to: stableURL)
                        cont.resume(returning: stableURL)
                    } catch { cont.resume(throwing: error) }
                }
                sessionTask = task
                // Poll progress until task finishes (state → .completed/.canceling)
                Task.detached {
                    while task.state == .running || task.state == .suspended {
                        onProgress(task.progress.fractionCompleted)
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                task.resume()
            }
        } onCancel: {
            sessionTask?.cancel()
        }

        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        if corpusDB != nil { sqlite3_close(corpusDB); corpusDB = nil }
        openCorpus()
    }

    /// Copy a corpus.db from a security-scoped URL into Documents and reopen.
    func importCorpus(from sourceURL: URL) throws {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destURL = docsURL.appendingPathComponent("corpus.db")

        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        guard hasAccess else { throw ImportError.accessDenied }

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ImportError.copyFailed(error)
        }

        // Close current corpus and reopen from the new file
        if corpusDB != nil { sqlite3_close(corpusDB); corpusDB = nil }
        openCorpus()
    }

    var corpusArticleCount: Int {
        var count = 0
        queryCorpus("SELECT COUNT(*) FROM articles;") { stmt in
            count = DatabaseService.int(stmt, 0)
        }
        return count
    }
}

// MARK: - Bindable values

enum SQLiteValue {
    case text(String)
    case int64(Int64)
    case double(Double)
    case blob(Data)
    case null

    func bind(to stmt: OpaquePointer?, at index: Int32) {
        switch self {
        case .text(let s):  sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
        case .int64(let i): sqlite3_bind_int64(stmt, index, i)
        case .double(let d): sqlite3_bind_double(stmt, index, d)
        case .blob(let data):
            _ = data.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        case .null: sqlite3_bind_null(stmt, index)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
