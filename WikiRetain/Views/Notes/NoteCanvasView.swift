import SwiftUI
import PencilKit

struct NoteCanvasView: View {
    @EnvironmentObject var appState: AppState
    let article: Article
    var onSave: (() -> Void)? = nil

    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    @State private var note: Note
    @State private var saveState: SaveState = .idle
    @State private var showViewer = false
    @State private var backgroundStyle: CanvasBackground = .lined
    @Environment(\.dismiss) var dismiss

    enum CanvasBackground: String, CaseIterable {
        case blank, lined, grid
        var icon: String {
            switch self {
            case .blank: "doc"
            case .lined: "line.3.horizontal"
            case .grid: "grid"
            }
        }
    }

    enum SaveState {
        case idle, saving, saved, error
        var label: String {
            switch self {
            case .idle:   return ""
            case .saving: return "Processing…"
            case .saved:  return "Saved"
            case .error:  return "Error"
            }
        }
        var icon: String {
            switch self {
            case .idle:   return ""
            case .saving: return "ellipsis.circle"
            case .saved:  return "checkmark.circle.fill"
            case .error:  return "exclamationmark.circle.fill"
            }
        }
    }

    init(article: Article, onSave: (() -> Void)? = nil) {
        self.article = article
        self.onSave = onSave
        _note = State(initialValue: Note(articleId: article.id))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                BackgroundView(style: backgroundStyle)
                CanvasRepresentable(
                    canvasView: $canvasView,
                    toolPicker: toolPicker,
                    onDrawingChanged: { debouncedSave() }
                )
            }

            // Status pill — only visible when active
            if saveState != .idle {
                statusPill
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: saveState == .idle)
        .navigationTitle("Draw Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(CanvasBackground.allCases, id: \.self) { bg in
                        Button {
                            backgroundStyle = bg
                        } label: {
                            Label(bg.rawValue.capitalized, systemImage: bg.icon)
                        }
                    }
                } label: {
                    Image(systemName: backgroundStyle.icon)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("View Notes") { showViewer = true }
                    .disabled(note.markdown == nil && note.ocrText == nil)
            }
        }
        .sheet(isPresented: $showViewer) {
            NoteViewerView(note: note, article: article)
        }
        .onAppear { setupCanvas() }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if saveState == .saving {
                ProgressView().scaleEffect(0.75)
            } else {
                Image(systemName: saveState.icon)
                    .foregroundStyle(saveState == .saved ? .green : .red)
            }
            Text(saveState.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }

    // MARK: - Setup

    private func setupCanvas() {
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        let existing = appState.noteService.notes(for: article.id)
        if let first = existing.first, let inkData = first.inkData,
           let drawing = try? PKDrawing(data: inkData) {
            canvasView.drawing = drawing
            note = first
        }
    }

    // MARK: - Auto-save with 2s debounce (per plan NT-02)

    private var debounceTask: Task<Void, Never>? {
        get { nil }   // storage handled via @State below
        set { }
    }
    @State private var _debounceTask: Task<Void, Never>?

    private func debouncedSave() {
        _debounceTask?.cancel()
        _debounceTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await processAndSave()
        }
    }

    @MainActor
    private func processAndSave() async {
        guard !canvasView.drawing.strokes.isEmpty else { return }

        withAnimation { saveState = .saving }

        note.inkData = canvasView.drawing.dataRepresentation()
        note.updatedAt = Date()

        let bounds = canvasView.drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 800, height: 600)
            : canvasView.drawing.bounds
        let image = canvasView.drawing.image(from: bounds, scale: 2.0)
        guard let cgImage = image.cgImage else {
            withAnimation { saveState = .error }
            return
        }

        do {
            let ocrText = try await appState.ocrService.recognize(image: cgImage)
            note.ocrText = ocrText

            if appState.aiAvailable && !ocrText.isEmpty {
                let result = try await appState.aiService.processNote(
                    ocrText: ocrText,
                    articleTitle: article.title,
                    articleExcerpt: article.snippet
                )
                note.markdown = result.markdown
                note.ocrText = result.correctedText
                note.llmConfidence = result.confidence
                note.factualIssues = result.factualIssues.map {
                    Note.FactualIssue(id: UUID().uuidString, description: $0, severity: .minor)
                }
            } else {
                note.markdown = "## Notes\n\n\(ocrText)"
            }

            appState.noteService.save(note)
            onSave?()
            withAnimation { saveState = .saved }

            // Fade back to idle after 2s
            try? await Task.sleep(for: .seconds(2))
            withAnimation { saveState = .idle }
        } catch {
            withAnimation { saveState = .error }
        }
    }
}

// MARK: - Canvas UIViewRepresentable

struct CanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let toolPicker: PKToolPicker
    let onDrawingChanged: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDrawingChanged: onDrawingChanged) }

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.delegate = context.coordinator
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: () -> Void
        init(onDrawingChanged: @escaping () -> Void) { self.onDrawingChanged = onDrawingChanged }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { onDrawingChanged() }
    }
}

// MARK: - Background

private struct BackgroundView: View {
    let style: NoteCanvasView.CanvasBackground

    var body: some View {
        switch style {
        case .blank:
            Color(.systemBackground)
        case .lined:
            LinedBackground()
        case .grid:
            GridBackground()
        }
    }
}

private struct LinedBackground: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let spacing: CGFloat = 32
                var y: CGFloat = spacing
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
                    y += spacing
                }
            }
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}

private struct GridBackground: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let spacing: CGFloat = 24
                var x: CGFloat = 0
                while x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
                    y += spacing
                }
            }
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}
