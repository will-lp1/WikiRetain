import Foundation
import SwiftUI

struct GraphNode: Identifiable, Hashable {
    let articleId: Int64
    var title: String
    var firstVisited: Date?
    var clusterId: String?
    var summaryCache: String?

    // Runtime positioning
    var position: CGPoint = .zero
    var velocity: CGPoint = .zero

    var id: Int64 { articleId }

    var status: NodeStatus
    var isGap: Bool   // unvisited but linked from a read article

    enum NodeStatus: Hashable {
        case unvisited   // grey hollow (gap)
        case read        // blue
        case hasNotes    // green
        case dueToday    // amber
        case overdue     // red
    }

    var color: Color {
        if isGap { return .gray.opacity(0.5) }
        switch status {
        case .unvisited: return .gray
        case .read: return .blue
        case .hasNotes: return .green
        case .dueToday: return .orange
        case .overdue: return .red
        }
    }
}

struct GraphEdge: Identifiable, Hashable {
    let fromId: Int64
    let toId: Int64
    let edgeType: EdgeType
    let createdAt: Date

    var id: String { "\(fromId)-\(toId)-\(edgeType.rawValue)" }

    enum EdgeType: String, Hashable {
        case navigation
        case wikilink
    }
}
