import SwiftUI
import PencilKit

struct NoteViewerView: View {
    @EnvironmentObject var appState: AppState
    @State private var note: Note
    let article: Article

    @State private var selectedTab = 0
    @State private var isEditing = false
    @State private var markdownDraft = ""
    @Environment(\.dismiss) var dismiss

    init(note: Note, article: Article) {
        _note = State(initialValue: note)
        self.article = article
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text("Ink").tag(0)
                Text("OCR Text").tag(1)
                Text("Markdown").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            TabView(selection: $selectedTab) {
                InkTab(inkData: note.inkData).tag(0)

                ScrollView {
                    Text(note.ocrText ?? "No OCR text available.")
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tag(1)

                markdownTab.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if !note.factualIssues.isEmpty {
                Divider()
                FactualIssuesBar(issues: note.factualIssues)
            }
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    Button("Cancel") {
                        markdownDraft = note.markdown ?? ""
                        isEditing = false
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if selectedTab == 2 {
                    if isEditing {
                        Button("Save") { saveEdit() }
                            .fontWeight(.semibold)
                    } else {
                        Button("Edit") {
                            markdownDraft = note.markdown ?? ""
                            isEditing = true
                        }
                    }
                } else if let confidence = note.llmConfidence {
                    Label("\(Int(confidence * 100))%", systemImage: "checkmark.seal")
                        .foregroundStyle(confidence > 0.8 ? .green : .orange)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var markdownTab: some View {
        if isEditing {
            TextEditor(text: $markdownDraft)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        } else {
            ScrollView {
                MarkdownView(markdown: note.markdown ?? "*No notes processed yet.*")
                    .padding()
            }
        }
    }

    private func saveEdit() {
        note.markdown = markdownDraft
        note.updatedAt = Date()
        appState.noteService.save(note)
        isEditing = false
    }
}

// MARK: - Ink tab

private struct InkTab: View {
    let inkData: Data?

    var body: some View {
        if let data = inkData, let drawing = try? PKDrawing(data: data) {
            InkCanvasView(drawing: drawing)
        } else {
            ContentUnavailableView("No ink", systemImage: "pencil.slash")
        }
    }
}

private struct InkCanvasView: UIViewRepresentable {
    let drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let cv = PKCanvasView()
        cv.drawing = drawing
        cv.isUserInteractionEnabled = false
        cv.backgroundColor = .clear
        return cv
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.drawing = drawing
    }
}

// MARK: - Markdown renderer

private struct MarkdownView: View {
    let markdown: String

    var body: some View {
        if let attr = try? AttributedString(markdown: markdown) {
            Text(attr)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Factual issues

private struct FactualIssuesBar: View {
    let issues: [Note.FactualIssue]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(issues.count) factual issue\(issues.count == 1 ? "" : "s") flagged")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if expanded {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(issue.severity == .major ? .red : .orange)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(issue.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.1))
    }
}
