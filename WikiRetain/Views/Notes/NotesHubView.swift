import SwiftUI
import PencilKit

struct NotesHubView: View {
    @EnvironmentObject var appState: AppState
    let article: Article

    @State private var notes: [Note] = []
    @State private var path: [NoteDestination] = []
    @Environment(\.dismiss) var dismiss

    enum NoteDestination: Hashable {
        case canvas
        case importPhoto
        case viewer(String) // note id
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if notes.isEmpty {
                    emptyState
                } else {
                    noteList
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { path.append(.importPhoto) } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                    Button { path.append(.canvas) } label: {
                        Image(systemName: "pencil")
                    }
                }
            }
            .navigationDestination(for: NoteDestination.self) { dest in
                switch dest {
                case .canvas:
                    NoteCanvasView(article: article, onSave: reload)
                case .importPhoto:
                    NoteImportView(article: article)
                case .viewer(let noteId):
                    if let note = notes.first(where: { $0.id == noteId }) {
                        NoteViewerView(note: note, article: article)
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        notes = appState.noteService.notes(for: article.id)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Notes Yet", systemImage: "note.text")
        } description: {
            Text("Draw with the pencil or import a photo of your notebook.")
        } actions: {
            HStack(spacing: 12) {
                Button { path.append(.canvas) } label: {
                    Label("Draw", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button { path.append(.importPhoto) } label: {
                    Label("Import Photo", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Note list

    private var noteList: some View {
        List {
            ForEach(notes) { note in
                NoteRowView(note: note)
                    .contentShape(Rectangle())
                    .onTapGesture { path.append(.viewer(note.id)) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            appState.noteService.delete(note.id)
                            reload()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Note row

private struct NoteRowView: View {
    let note: Note

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

            VStack(alignment: .leading, spacing: 4) {
                if let md = note.markdown, !md.isEmpty {
                    Text(firstLine(of: md))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(md)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let ocr = note.ocrText {
                    Text(ocr)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Processing…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let conf = note.llmConfidence {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(Int(conf * 100))% confidence")
                            .font(.caption2)
                            .foregroundStyle(conf > 0.8 ? .green : .orange)
                    }
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = note.inkData, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty {
            InkThumbnail(drawing: drawing)
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: "note.text")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func firstLine(of markdown: String) -> String {
        let line = markdown
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? markdown
        return line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
    }
}

private struct InkThumbnail: UIViewRepresentable {
    let drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let cv = PKCanvasView()
        cv.drawing = drawing
        cv.isUserInteractionEnabled = false
        cv.backgroundColor = .systemBackground
        cv.transform = scaleToFit(drawing: drawing, in: CGSize(width: 60, height: 60))
        return cv
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    private func scaleToFit(drawing: PKDrawing, in size: CGSize) -> CGAffineTransform {
        let bounds = drawing.bounds
        guard bounds.width > 0, bounds.height > 0 else { return .identity }
        let scale = min(size.width / bounds.width, size.height / bounds.height) * 0.85
        let tx = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        let ty = (size.height - bounds.height * scale) / 2 - bounds.minY * scale
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}
