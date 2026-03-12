import Foundation
import SwiftUI
import SQLite3

@MainActor
final class GraphService: ObservableObject {
    private let db: DatabaseService

    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []

    init(db: DatabaseService) {
        self.db = db
    }

    func reload(noteService: NoteService, reviewService: ReviewService) async {
        var loadedNodes: [GraphNode] = []
        var gapIds: Set<Int64> = []

        // Load read nodes
        var nodeRows: [(id: Int64, firstVisited: Date?, summaryCache: String?, readAt: Date?, dueDate: Date?)] = []
        db.queryUser("""
            SELECT gn.article_id, gn.first_visited, gn.summary_cache,
                   ua.read_at, sc.due_date
            FROM graph_nodes gn
            LEFT JOIN user_articles ua ON gn.article_id = ua.article_id
            LEFT JOIN srs_cards sc ON gn.article_id = sc.article_id
            ORDER BY gn.first_visited DESC;
        """) { stmt in
            nodeRows.append((
                id: DatabaseService.int64(stmt, 0),
                firstVisited: DatabaseService.date(stmt, 1),
                summaryCache: DatabaseService.optText(stmt, 2),
                readAt: DatabaseService.date(stmt, 3),
                dueDate: DatabaseService.date(stmt, 4)
            ))
        }

        for row in nodeRows {
            let id = row.id
            var title = "Article \(id)"
            var category: String? = nil
            // Fetch title AND category from corpus in one query
            db.queryCorpus("SELECT title, category FROM articles WHERE id = ?;", bindings: [.int64(id)]) { stmt in
                title = DatabaseService.text(stmt, 0)
                category = DatabaseService.optText(stmt, 1)
            }

            let hasNotes = noteService.hasNotes(articleId: id)
            let now = Date()
            let status: GraphNode.NodeStatus
            if let due = row.dueDate, due < now {
                let hoursOverdue = now.timeIntervalSince(due) / 3600
                status = hoursOverdue > 48 ? .overdue : .dueToday
            } else if hasNotes {
                status = .hasNotes
            } else if row.readAt != nil {
                status = .read
            } else {
                status = .unvisited
            }

            let node = GraphNode(articleId: id, title: title, firstVisited: row.firstVisited,
                                 clusterId: category, summaryCache: row.summaryCache,
                                 status: status, isGap: false)
            loadedNodes.append(node)
        }

        let readIds = Set(loadedNodes.map { $0.articleId })

        // Compute gap node IDs from wikilinks of read nodes
        for node in loadedNodes {
            db.queryCorpus("SELECT wikilinks FROM articles WHERE id = ?;",
                            bindings: [.int64(node.articleId)]) { stmt in
                let wikilinkJSON = DatabaseService.optText(stmt, 0) ?? "[]"
                if let ids = try? JSONDecoder().decode([Int64].self, from: wikilinkJSON.data(using: .utf8) ?? Data()) {
                    for wid in ids where !readIds.contains(wid) {
                        gapIds.insert(wid)
                    }
                }
            }
        }

        // Add gap nodes (with their category for visual grouping)
        for gapId in gapIds {
            var title = "Article \(gapId)"
            var category: String? = nil
            db.queryCorpus("SELECT title, category FROM articles WHERE id = ?;",
                            bindings: [.int64(gapId)]) { stmt in
                title = DatabaseService.text(stmt, 0)
                category = DatabaseService.optText(stmt, 1)
            }
            let gapNode = GraphNode(articleId: gapId, title: title, firstVisited: nil,
                                    clusterId: category, summaryCache: nil,
                                    status: .unvisited, isGap: true)
            loadedNodes.append(gapNode)
        }

        let allNodeIds = Set(loadedNodes.map { $0.articleId })

        // Build edges exclusively from corpus wikilinks — no random navigation edges
        var loadedEdges: [GraphEdge] = []
        var edgeSet: Set<String> = []
        for node in loadedNodes where !node.isGap {
            db.queryCorpus("SELECT wikilinks FROM articles WHERE id = ?;",
                            bindings: [.int64(node.articleId)]) { stmt in
                let wikilinkJSON = DatabaseService.optText(stmt, 0) ?? "[]"
                if let ids = try? JSONDecoder().decode([Int64].self, from: wikilinkJSON.data(using: .utf8) ?? Data()) {
                    for wid in ids where allNodeIds.contains(wid) && wid != node.articleId {
                        let key = "\(node.articleId)-\(wid)"
                        if !edgeSet.contains(key) {
                            edgeSet.insert(key)
                            loadedEdges.append(GraphEdge(fromId: node.articleId, toId: wid,
                                                         edgeType: .wikilink, createdAt: Date()))
                        }
                    }
                }
            }
        }

        self.nodes = loadedNodes
        self.edges = loadedEdges
    }

    func cacheSummary(articleId: Int64, summary: String) {
        db.prepareUser("""
            UPDATE graph_nodes SET summary_cache = ? WHERE article_id = ?;
        """) { stmt in
            sqlite3_bind_text(stmt, 1, summary, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, articleId)
            sqlite3_step(stmt)
        }
    }

    func recordWikilinkEdge(from fromId: Int64, to toId: Int64) {
        let now = Date().timeIntervalSince1970
        db.prepareUser("""
            INSERT OR IGNORE INTO graph_edges(from_id, to_id, edge_type, created_at)
            VALUES(?,?,'wikilink',?);
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, fromId)
            sqlite3_bind_int64(stmt, 2, toId)
            sqlite3_bind_double(stmt, 3, now)
            sqlite3_step(stmt)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
