import SwiftUI

struct MindMapView: View {
    @EnvironmentObject var appState: AppState
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var selectedNode: GraphNode?   // long-press → detail sheet
    @State private var articleToOpen: Article?    // tap → push navigation
    @State private var loadingNodeId: Int64?      // shows spinner while fetching
    @State private var isLoading = true

    // Canvas transform state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gesturePan: CGSize = .zero

    // Persist positions across reloads within a session
    @State private var positionCache: [Int64: CGPoint] = [:]

    // Force simulation
    @State private var simulationTimer: Timer?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if isLoading {
                ProgressView("Building mind map…")
            } else if nodes.isEmpty {
                EmptyGraphView()
            } else {
                graphCanvas
            }
        }
        .task { await loadGraph() }
        // Tap: push article onto the navigation stack (KG-06)
        .navigationDestination(item: $articleToOpen) { article in
            ArticleView(article: article)
        }
        // Long-press: summary detail sheet (KG-07)
        .sheet(item: $selectedNode) { node in
            NodeDetailSheet(node: node, onOpenArticle: { article in
                selectedNode = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    articleToOpen = article
                }
            })
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            ZStack {
                // Edges + category backgrounds
                Canvas { ctx, size in
                    let transform = CGAffineTransform(
                        translationX: size.width / 2 + offset.width + gesturePan.width,
                        y: size.height / 2 + offset.height + gesturePan.height
                    ).scaledBy(x: scale * gestureScale, y: scale * gestureScale)

                    // Draw faint category cluster bubbles
                    var clusterSum: [String: CGPoint] = [:]
                    var clusterCounts: [String: Int] = [:]
                    for n in nodes {
                        guard let cid = n.clusterId else { continue }
                        let prev = clusterSum[cid] ?? .zero
                        clusterSum[cid] = CGPoint(x: prev.x + n.position.x, y: prev.y + n.position.y)
                        clusterCounts[cid] = (clusterCounts[cid] ?? 0) + 1
                    }
                    for (cid, sum) in clusterSum {
                        let cnt = CGFloat(clusterCounts[cid] ?? 1)
                        let centroid = CGPoint(x: sum.x / cnt, y: sum.y / cnt)
                        // Compute max distance from centroid to any member
                        var maxDist: CGFloat = 60
                        for n in nodes where n.clusterId == cid {
                            let dx = n.position.x - centroid.x
                            let dy = n.position.y - centroid.y
                            maxDist = max(maxDist, sqrt(dx*dx + dy*dy) + 60)
                        }
                        let center = centroid.applying(transform)
                        let radius = maxDist * scale * gestureScale
                        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2)
                        let clusterPath = Path(ellipseIn: rect)
                        // Stable color per category name
                        let hue = Double(abs(cid.hashValue) % 360) / 360.0
                        ctx.fill(clusterPath, with: .color(Color(hue: hue, saturation: 0.4, brightness: 0.9).opacity(0.08)))
                        ctx.stroke(clusterPath, with: .color(Color(hue: hue, saturation: 0.4, brightness: 0.7).opacity(0.18)), lineWidth: 1)

                        // Category label
                        let label = cid.count > 22 ? String(cid.prefix(22)) + "…" : cid
                        ctx.draw(Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hue: hue, saturation: 0.5, brightness: 0.5).opacity(0.7)),
                                 at: CGPoint(x: center.x, y: center.y - radius - 2),
                                 anchor: .bottom)
                    }

                    // Draw edges
                    let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.articleId, $0) })
                    for edge in edges {
                        guard let from = nodeMap[edge.fromId], let to = nodeMap[edge.toId] else { continue }
                        var path = Path()
                        path.move(to: from.position.applying(transform))
                        path.addLine(to: to.position.applying(transform))
                        ctx.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 1.0)
                    }
                }

                // Nodes
                ForEach(nodes) { node in
                    NodeView(node: node, isSelected: selectedNode?.articleId == node.articleId)
                        .position(
                            x: geo.size.width / 2 + offset.width + gesturePan.width + node.position.x * scale * gestureScale,
                            y: geo.size.height / 2 + offset.height + gesturePan.height + node.position.y * scale * gestureScale
                        )
                        .onTapGesture { openArticle(for: node) }
                        .onLongPressGesture(minimumDuration: 0.5) { selectedNode = node }
                        .overlay {
                            if loadingNodeId == node.articleId {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            }
                        }
                }
            }
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { v, s, _ in s = v }
                        .onEnded { scale = min(max(scale * $0, 0.04), 4.0) },
                    DragGesture()
                        .updating($gesturePan) { v, s, _ in s = v.translation }
                        .onEnded { offset = CGSize(width: offset.width + $0.translation.width,
                                                   height: offset.height + $0.translation.height) }
                )
            )
        }
    }

    // MARK: - Load

    private func loadGraph() async {
        await appState.graphService.reload(
            noteService: appState.noteService,
            reviewService: appState.reviewService
        )

        var loadedNodes = appState.graphService.nodes
        let loadedEdges = appState.graphService.edges

        // Restore cached positions for known nodes; place new nodes grouped by category
        let newNodes = loadedNodes.filter { positionCache[$0.articleId] == nil }

        // Assign a sector angle to each unique category so same-category nodes start nearby
        var categoryAngles: [String: CGFloat] = [:]
        let uniqueCategories = Array(Set(newNodes.compactMap { $0.clusterId }))
        for (idx, cat) in uniqueCategories.enumerated() {
            categoryAngles[cat] = CGFloat(idx) / CGFloat(max(uniqueCategories.count, 1)) * 2 * .pi
        }

        // Track per-category placement index for spacing within a sector
        var categoryPlacementIndex: [String: Int] = [:]

        for i in loadedNodes.indices {
            let id = loadedNodes[i].articleId
            if let cached = positionCache[id] {
                loadedNodes[i].position = cached
            } else {
                let baseRadius: CGFloat = loadedNodes[i].isGap ? 280 : 160
                let cat = loadedNodes[i].clusterId
                let sectorAngle = cat.flatMap { categoryAngles[$0] } ?? CGFloat.random(in: 0..<(2 * .pi))
                let idx = cat.flatMap { categoryPlacementIndex[$0] } ?? 0
                if let c = cat { categoryPlacementIndex[c] = idx + 1 }
                // Spread nodes within the sector with a small angular offset and staggered radius
                let spread: CGFloat = 0.35
                let angleOffset = CGFloat(idx % 5) * spread - spread * 2
                let angle = sectorAngle + angleOffset
                let tier = CGFloat(idx / 5) * 90
                loadedNodes[i].position = CGPoint(
                    x: cos(angle) * (baseRadius + tier),
                    y: sin(angle) * (baseRadius + tier)
                )
            }
        }

        nodes = loadedNodes
        edges = loadedEdges
        isLoading = false

        startForceSimulation()
    }

    // MARK: - Node tap → open article

    private func openArticle(for node: GraphNode) {
        guard loadingNodeId == nil else { return }
        loadingNodeId = node.articleId
        Task {
            if let article = await appState.articleService.article(id: node.articleId) {
                articleToOpen = article
            }
            loadingNodeId = nil
        }
    }

    // MARK: - Force-directed simulation

    private func startForceSimulation() {
        simulationTimer?.invalidate()
        var iteration = 0
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            iteration += 1
            self.nodes = ForceLayout.step(nodes: self.nodes, edges: self.edges)
            // Cache positions every frame so reloads don't scramble layout
            for node in self.nodes {
                self.positionCache[node.articleId] = node.position
            }
            if iteration > 180 {
                self.simulationTimer?.invalidate()
            }
        }
    }
}

// MARK: - Force Layout

enum ForceLayout {
    static let repulsion: CGFloat = 7000
    static let attraction: CGFloat = 0.06
    static let damping: CGFloat = 0.80
    static let maxVelocity: CGFloat = 8.0
    static let centerGravity: CGFloat = 0.012
    static let clusterForce: CGFloat = 0.04   // pull same-category nodes toward their centroid

    static func step(nodes: [GraphNode], edges: [GraphEdge]) -> [GraphNode] {
        var updated = nodes
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.articleId, $0.offset) })

        // Compute per-category centroids
        var clusterSum: [String: CGPoint] = [:]
        var clusterCount: [String: Int] = [:]
        for n in updated {
            if let cid = n.clusterId {
                clusterSum[cid] = CGPoint(
                    x: (clusterSum[cid]?.x ?? 0) + n.position.x,
                    y: (clusterSum[cid]?.y ?? 0) + n.position.y
                )
                clusterCount[cid] = (clusterCount[cid] ?? 0) + 1
            }
        }
        var clusterCentroid: [String: CGPoint] = [:]
        for (cid, sum) in clusterSum {
            let cnt = CGFloat(clusterCount[cid] ?? 1)
            clusterCentroid[cid] = CGPoint(x: sum.x / cnt, y: sum.y / cnt)
        }

        for i in updated.indices {
            var fx: CGFloat = 0
            var fy: CGFloat = 0

            // Repulsion between all pairs
            for j in updated.indices where i != j {
                let dx = updated[i].position.x - updated[j].position.x
                let dy = updated[i].position.y - updated[j].position.y
                let dist2 = max(dx * dx + dy * dy, 1)
                fx += repulsion * dx / dist2
                fy += repulsion * dy / dist2
            }

            // Attraction along edges
            for edge in edges {
                let partnerId: Int64? = edge.fromId == updated[i].articleId ? edge.toId
                                      : edge.toId == updated[i].articleId ? edge.fromId : nil
                if let pid = partnerId, let j = nodeMap[pid] {
                    let dx = updated[j].position.x - updated[i].position.x
                    let dy = updated[j].position.y - updated[i].position.y
                    fx += attraction * dx
                    fy += attraction * dy
                }
            }

            // Cluster force — pull toward category centroid
            if let cid = updated[i].clusterId, let centroid = clusterCentroid[cid] {
                fx += (centroid.x - updated[i].position.x) * clusterForce
                fy += (centroid.y - updated[i].position.y) * clusterForce
            }

            // Centre gravity
            fx -= updated[i].position.x * centerGravity
            fy -= updated[i].position.y * centerGravity

            // Update velocity and position
            updated[i].velocity.x = (updated[i].velocity.x + fx) * damping
            updated[i].velocity.y = (updated[i].velocity.y + fy) * damping
            updated[i].velocity.x = max(min(updated[i].velocity.x, maxVelocity), -maxVelocity)
            updated[i].velocity.y = max(min(updated[i].velocity.y, maxVelocity), -maxVelocity)
            updated[i].position.x += updated[i].velocity.x
            updated[i].position.y += updated[i].velocity.y
        }
        return updated
    }
}

// MARK: - Node View

private struct NodeView: View {
    let node: GraphNode
    let isSelected: Bool

    var size: CGFloat { node.isGap ? 50 : 80 }

    var body: some View {
        ZStack {
            if node.isGap {
                Circle()
                    .stroke(node.color, lineWidth: 2)
                    .frame(width: size, height: size)
                Text("?")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(node.color)
            } else {
                Circle()
                    .fill(node.color.gradient)
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().stroke(isSelected ? .white : .clear, lineWidth: 3)
                    )
                    .shadow(color: node.color.opacity(0.5), radius: isSelected ? 12 : 4)
            }
        }
        .overlay(alignment: .bottom) {
            Text(node.title)
                .font(.system(size: node.isGap ? 10 : 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: size + 20)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: size / 2 + 6)
        }
    }
}

// MARK: - Node Detail Sheet

private struct NodeDetailSheet: View {
    @EnvironmentObject var appState: AppState
    let node: GraphNode
    /// Called when the user wants to open the article (dismisses sheet first).
    let onOpenArticle: (Article) -> Void
    @State private var article: Article?
    @State private var summary: String = ""
    @State private var isGeneratingSummary = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let article {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(article.title).font(.headline)
                            if let cat = article.category {
                                Label(cat, systemImage: "tag").font(.caption).foregroundStyle(.blue)
                            }
                            if article.isRead {
                                Label("Read", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !summary.isEmpty {
                    Section("Summary") {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if appState.aiAvailable && summary.isEmpty {
                    Section {
                        Button {
                            generateSummary()
                        } label: {
                            if isGeneratingSummary {
                                ProgressView()
                            } else {
                                Label("Generate Summary", systemImage: "wand.and.stars")
                            }
                        }
                        .disabled(isGeneratingSummary)
                    }
                }
                if let article {
                    Section {
                        Button {
                            onOpenArticle(article)
                        } label: {
                            Label("Open Article", systemImage: "doc.text")
                        }
                    }
                }
            }
            .navigationTitle(node.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadArticle() }
        }
    }

    private func loadArticle() async {
        article = await appState.articleService.article(id: node.articleId)
        summary = node.summaryCache ?? ""
    }

    private func generateSummary() {
        guard let article else { return }
        isGeneratingSummary = true
        summary = ""
        Task {
            do {
                let stream = try appState.aiService.streamNodeSummary(
                    articleTitle: article.title,
                    articleExcerpt: article.snippet
                )
                for try await snapshot in stream {
                    summary = snapshot.content
                }
                appState.graphService.cacheSummary(articleId: node.articleId, summary: summary)
            } catch {
                summary = (try? await appState.aiService.generateNodeSummary(
                    articleTitle: article.title,
                    articleExcerpt: article.snippet
                )) ?? ""
            }
            isGeneratingSummary = false
        }
    }
}

// MARK: - Empty State

private struct EmptyGraphView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No knowledge graph yet")
                .font(.title3.bold())
            Text("Search for an article to begin building your knowledge map.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}
