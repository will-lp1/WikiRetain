import SwiftUI
import WebKit

struct ArticleView: View {
    @EnvironmentObject var appState: AppState
    let article: Article

    @AppStorage("fontSizeOffset") private var fontSizeOffset: Int = 0
    @AppStorage("colorScheme")    private var colorScheme: String = "system"

    @State private var fullArticle: Article?
    @State private var wikilinks: [Article] = []
    @State private var showNotes = false
    @State private var showTOC = false
    @State private var isMarkedRead = false
    @State private var breadcrumb: [Article] = []
    @State private var previewArticle: Article?
    @State private var previewText: String?
    @State private var showPreview = false

    var displayArticle: Article { fullArticle ?? article }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Breadcrumb
                if !breadcrumb.isEmpty {
                    BreadcrumbBar(
                        breadcrumb: breadcrumb,
                        currentTitle: displayArticle.title
                    ) { idx in
                        navigateBack(to: idx)
                    }
                }

                // Article web view
                ArticleWebView(
                    article: displayArticle,
                    wikilinks: wikilinks,
                    fontSizeOffset: fontSizeOffset,
                    colorScheme: colorScheme
                ) { linkedId in
                    navigateTo(linkedId)
                } onLinkLongPress: { linkedId in
                    showWikilinkPreview(linkedId)
                } onScrollProgress: { frac in
                    let aid = displayArticle.id   // track the article currently on screen
                    Task { await appState.articleService.saveScrollPosition(aid, fraction: frac) }
                } onScrolledToEnd: {
                    markAsRead()
                }
            }

            // Floating action buttons
            VStack(spacing: 12) {
                // Notes button
                Button {
                    showNotes = true
                } label: {
                    Image(systemName: "pencil.and.outline")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.blue)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }

                // TOC button
                Button {
                    showTOC = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 2)
                }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 40)
        }
        .navigationTitle(displayArticle.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleRead()
                } label: {
                    Image(systemName: isMarkedRead ? "checkmark.circle.fill" : "circle")
                }
                .tint(isMarkedRead ? .green : .blue)
            }
        }
        .task { await loadArticle() }
        .sheet(isPresented: $showNotes) {
            NotesHubView(article: displayArticle)
        }
        .sheet(isPresented: $showTOC) {
            TOCView(html: displayArticle.bodyHTML)
        }
        .sheet(isPresented: $showPreview) {
            if let linked = previewArticle {
                WikilinkPreviewView(
                    article: linked,
                    previewText: previewText,
                    onNavigate: {
                        showPreview = false
                        navigateTo(linked.id)
                    }
                )
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func loadArticle() async {
        let loaded = await appState.articleService.article(id: article.id) ?? article
        let links  = await appState.articleService.wikilinks(for: loaded)
        // Assign together so SwiftUI batches into one render (no double-load)
        fullArticle   = loaded
        wikilinks     = links
        isMarkedRead  = loaded.isRead
    }

    private func markAsRead() {
        guard !isMarkedRead else { return }
        toggleRead()
    }

    private func toggleRead() {
        isMarkedRead.toggle()
        let aid = displayArticle.id   // the article currently on screen
        Task {
            if isMarkedRead {
                await appState.articleService.markAsRead(aid)
                appState.reviewService.scheduleNewArticle(articleId: aid)
            } else {
                await appState.articleService.markAsUnread(aid)
            }
            appState.reviewService.refreshDueCount()
        }
    }

    private func showWikilinkPreview(_ linkedId: Int64) {
        guard let linked = wikilinks.first(where: { $0.id == linkedId }) else { return }
        previewArticle = linked
        previewText = nil
        showPreview = true
        Task {
            // Fetch full article for excerpt, then generate AI preview
            let full = await appState.articleService.article(id: linkedId) ?? linked
            if appState.aiAvailable {
                let bodyText = full.bodyHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                previewText = try? await appState.aiService.generateNodeSummary(
                    articleTitle: full.title,
                    articleExcerpt: bodyText
                )
            } else {
                // Fallback: first ~300 chars of plain text
                let bodyText = full.bodyHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                previewText = String(bodyText.prefix(300))
            }
        }
    }

    private func navigateTo(_ linkedId: Int64) {
        breadcrumb.append(displayArticle)
        Task {
            await appState.articleService.recordNavigation(from: displayArticle.id, to: linkedId)
            if let linked = await appState.articleService.article(id: linkedId) {
                let links = await appState.articleService.wikilinks(for: linked)
                fullArticle  = linked
                wikilinks    = links
                isMarkedRead = linked.isRead
            }
        }
    }

    /// Navigate back to breadcrumb[idx], trimming everything after it.
    private func navigateBack(to idx: Int) {
        let target = breadcrumb[idx]
        breadcrumb = Array(breadcrumb[0..<idx])
        Task {
            if let loaded = await appState.articleService.article(id: target.id) {
                let links = await appState.articleService.wikilinks(for: loaded)
                fullArticle  = loaded
                wikilinks    = links
                isMarkedRead = loaded.isRead
            }
        }
    }
}

// MARK: - Web View

struct ArticleWebView: UIViewRepresentable {
    let article: Article
    let wikilinks: [Article]
    var fontSizeOffset: Int = 0
    var colorScheme: String = "system"
    let onLinkTap: (Int64) -> Void
    let onLinkLongPress: (Int64) -> Void
    let onScrollProgress: (Double) -> Void
    let onScrolledToEnd: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "wikiLink")
        config.userContentController.add(context.coordinator, name: "wikiLinkPreview")
        config.userContentController.add(context.coordinator, name: "scrollProgress")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.showsVerticalScrollIndicator = true
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        let wikilinkIds = wikilinks.map(\.id)

        // Only reload when something meaningful changed — prevents scroll reset
        // when unrelated state (e.g. parent re-renders) triggers updateUIView.
        let isNewArticle = article.id != c.loadedArticleId
        let changed = isNewArticle
            || wikilinkIds != c.loadedWikilinkIds
            || fontSizeOffset != c.loadedFontSize
            || colorScheme != c.loadedColorScheme

        guard changed else { c.parent = self; return }

        if isNewArticle {
            // New article: restore its saved scroll position
            c.pendingScrollFraction = article.lastScrollFrac
            c.liveScrollFraction = 0
        } else {
            // Same article, metadata changed (wikilinks/font/scheme): preserve live scroll
            c.pendingScrollFraction = c.liveScrollFraction > 0.01 ? c.liveScrollFraction : article.lastScrollFrac
        }
        c.loadedArticleId    = article.id
        c.loadedWikilinkIds  = wikilinkIds
        c.loadedFontSize     = fontSizeOffset
        c.loadedColorScheme  = colorScheme

        wv.loadHTMLString(buildHTML(), baseURL: nil)
        c.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var resolvedFontSize: Int { 17 + fontSizeOffset }

    private var colorSchemeCSS: String {
        switch colorScheme {
        case "light":
            return "body { color: #1c1c1e; background: #ffffff; }"
        case "dark":
            return "body { color: #f2f2f7; background: #000000; } a { color: #5ac8fa; } table { border-color: #3a3a3c; }"
        case "sepia":
            return "body { color: #3b2d1f; background: #f5edd6; } a { color: #8b4513; }"
        default: // "system"
            return """
            @media (prefers-color-scheme: dark) {
              body { color: #f2f2f7; background: #000000; }
              a { color: #5ac8fa; }
              table { border-color: #3a3a3c; }
            }
            """
        }
    }

    private func buildHTML() -> String {
        let wikilinkMap = wikilinks.map { "\"\($0.id)\": \"\($0.title.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          :root { color-scheme: light dark; }
          body { font-family: -apple-system, Georgia, serif; font-size: \(resolvedFontSize)px;
                 line-height: 1.65; margin: 0; padding: 16px 20px 80px;
                 color: #1c1c1e; background: #ffffff; max-width: 700px; }
          \(colorSchemeCSS)
          h1 { font-size: 1.6em; font-weight: 700; margin-top: 1.5em; }
          h2 { font-size: 1.3em; font-weight: 600; margin-top: 1.4em;
               padding-bottom: 4px; border-bottom: 1px solid rgba(128,128,128,0.2); }
          h3 { font-size: 1.1em; font-weight: 600; }
          a.wikilink { color: #007aff; text-decoration: none; }
          a.wikilink:hover { text-decoration: underline; }
          a.wikilink.gap { color: #999; font-style: italic; }
          .table-wrap { overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 1em 0; }
          table { border-collapse: collapse; min-width: 100%; font-size: 0.85em; }
          th, td { padding: 6px 10px; border: 1px solid #d1d1d6; text-align: left; white-space: nowrap; }
          th { background: rgba(128,128,128,0.1); font-weight: 600; }
          blockquote { border-left: 3px solid #007aff; margin-left: 0;
                       padding-left: 16px; color: #6e6e73; }
          code { background: rgba(128,128,128,0.15); padding: 2px 5px;
                 border-radius: 4px; font-size: 0.9em; }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          .infobox { float: right; margin: 0 0 16px 16px; max-width: 280px;
                     font-size: 0.85em; border: 1px solid #d1d1d6;
                     border-radius: 8px; padding: 12px; background: rgba(128,128,128,0.05); }
        </style>
        </head>
        <body>
        <script>
          const wikilinkMap = {\(wikilinkMap)};
          function tapLink(id) {
            window.webkit.messageHandlers.wikiLink.postMessage(String(id));
          }
          function longPressLink(id) {
            window.webkit.messageHandlers.wikiLinkPreview.postMessage(String(id));
          }
          document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('table').forEach(function(t) {
              if (!t.parentElement.classList.contains('table-wrap')) {
                var w = document.createElement('div');
                w.className = 'table-wrap';
                t.parentNode.insertBefore(w, t);
                w.appendChild(t);
              }
            });
          });
          window.addEventListener('scroll', function() {
            const h = document.documentElement;
            const scrolled = h.scrollTop || document.body.scrollTop;
            const total = h.scrollHeight - h.clientHeight;
            const frac = total > 0 ? scrolled / total : 0;
            window.webkit.messageHandlers.scrollProgress.postMessage(frac.toFixed(4));
          }, {passive: true});
        </script>
        \(processedHTML())
        \(seeAlsoHTML())
        </body>
        </html>
        """
    }

    // Convert wikilinks to tappable JS handlers.
    // Handles both "Title_underscored" and "/wiki/Title_underscored" href formats.
    private func processedHTML() -> String {
        var titleToId: [String: Int64] = [:]
        for link in wikilinks {
            titleToId[link.title.replacingOccurrences(of: " ", with: "_")] = link.id
            titleToId[link.title] = link.id
        }

        guard let pattern = try? NSRegularExpression(pattern: "<a href=\"([^\"#?&]+)\">") else {
            return article.bodyHTML
        }

        let html = article.bodyHTML
        var result = ""
        var cursor = html.startIndex

        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let matchRange = Range(match.range, in: html),
                  let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            var href = String(html[hrefRange])
            result += html[cursor..<matchRange.lowerBound]
            // Strip /wiki/ prefix if present
            if href.hasPrefix("/wiki/") { href = String(href.dropFirst(6)) }
            let decoded = href.removingPercentEncoding ?? href
            let spaced = decoded.replacingOccurrences(of: "_", with: " ")
            if let id = titleToId[href] ?? titleToId[decoded] ?? titleToId[spaced] {
                result += "<a href=\"#\" onclick=\"tapLink(\(id));return false;\" oncontextmenu=\"longPressLink(\(id));return false;\" class=\"wikilink\">"
            } else {
                result += "<a class=\"wikilink gap\">"
            }
            cursor = matchRange.upperBound
        }
        result += html[cursor...]
        return result
    }

    // For articles whose HTML has no inline links (built with extracts API),
    // append a "See Also" section from the wikilinks array.
    private func seeAlsoHTML() -> String {
        guard !wikilinks.isEmpty else { return "" }
        // Only inject if no tappable links were found in the processed HTML
        let hasInlineLinks = article.bodyHTML.contains("<a href=")
        guard !hasInlineLinks else { return "" }
        let items = wikilinks.map { link -> String in
            let safeTitle = link.title.replacingOccurrences(of: "\"", with: "&quot;")
            return "<li><a href=\"#\" onclick=\"tapLink(\(link.id));return false;\" oncontextmenu=\"longPressLink(\(link.id));return false;\" class=\"wikilink\">\(safeTitle)</a></li>"
        }.joined(separator: "\n")
        return "<h2>See Also</h2><ul>\n\(items)\n</ul>"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ArticleWebView

        // Change-tracking — mirrors the last values passed to updateUIView
        var loadedArticleId: Int64 = -1
        var loadedWikilinkIds: [Int64] = []
        var loadedFontSize: Int = Int.min
        var loadedColorScheme: String = ""

        // Scroll to restore after next page-load finishes
        var pendingScrollFraction: Double = 0
        // Live scroll fraction updated as user scrolls (for same-article reloads)
        var liveScrollFraction: Double = 0

        init(_ parent: ArticleWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard pendingScrollFraction > 0.01 else { return }
            let frac = pendingScrollFraction
            pendingScrollFraction = 0
            // Slight delay lets the page layout settle before scrolling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let js = "var h=document.documentElement;h.scrollTop=(h.scrollHeight-h.clientHeight)*\(frac);"
                webView.evaluateJavaScript(js)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "wikiLink":
                if let idStr = message.body as? String, let id = Int64(idStr) {
                    parent.onLinkTap(id)
                }
            case "wikiLinkPreview":
                if let idStr = message.body as? String, let id = Int64(idStr) {
                    parent.onLinkLongPress(id)
                }
            case "scrollProgress":
                if let fracStr = message.body as? String, let frac = Double(fracStr) {
                    liveScrollFraction = frac
                    parent.onScrollProgress(frac)
                    if frac > 0.95 { parent.onScrolledToEnd() }
                }
            default: break
            }
        }

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .linkActivated ? .cancel : .allow
        }
    }
}

// MARK: - Breadcrumb

private struct BreadcrumbBar: View {
    /// History articles (not including the current one).
    let breadcrumb: [Article]
    /// Title of the currently displayed article.
    let currentTitle: String
    /// Called with the index in `breadcrumb` to navigate back to.
    let onNavigateBack: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(breadcrumb.enumerated()), id: \.offset) { idx, a in
                    Button {
                        onNavigateBack(idx)
                    } label: {
                        Text(a.title)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    separator
                }
                // Current article — not tappable, anchors the scroll
                Text(currentTitle)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .id("current")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // Always show the current (rightmost) item when the trail grows
        .defaultScrollAnchor(.trailing)
        .background(.regularMaterial)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }
}

// MARK: - TOC

private struct TOCView: View {
    let html: String
    @State private var headers: [(level: Int, text: String)] = []

    var body: some View {
        NavigationStack {
            List(headers.indices, id: \.self) { i in
                let header = headers[i]
                HStack {
                    if header.level > 1 {
                        Rectangle()
                            .frame(width: CGFloat(header.level - 1) * 12, height: 1)
                            .hidden()
                    }
                    Text(header.text)
                        .font(header.level == 1 ? .headline : .subheadline)
                        .foregroundStyle(header.level == 1 ? .primary : .secondary)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { headers = extractHeaders(from: html) }
    }

    private func extractHeaders(from html: String) -> [(level: Int, text: String)] {
        var results: [(Int, String)] = []
        let pattern = try? NSRegularExpression(pattern: "<h([1-4])[^>]*>(.*?)</h[1-4]>",
                                               options: [.caseInsensitive, .dotMatchesLineSeparators])
        let matches = pattern?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        for m in matches {
            if let levelRange = Range(m.range(at: 1), in: html),
               let textRange = Range(m.range(at: 2), in: html) {
                let level = Int(html[levelRange]) ?? 2
                let rawText = String(html[textRange])
                let stripped = rawText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !stripped.isEmpty {
                    results.append((level, stripped))
                }
            }
        }
        return results
    }
}

// MARK: - Wikilink Long-Press Preview

private struct WikilinkPreviewView: View {
    let article: Article
    let previewText: String?
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(article.title)
                    .font(.headline)
                Spacer()
                Button("Open", action: onNavigate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if let text = previewText {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Generating preview…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            Spacer()
        }
        .padding(24)
    }
}
