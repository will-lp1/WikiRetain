import SwiftUI
import PhotosUI

struct NoteImportView: View {
    @EnvironmentObject var appState: AppState
    let article: Article
    var onSave: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var sourceImage: UIImage?
    @State private var phase: Phase = .picking
    @State private var note: Note
    @State private var markdownDraft = ""
    @State private var errorMessage: String?

    enum Phase { case picking, processing, editing }

    init(article: Article) {
        self.article = article
        _note = State(initialValue: Note(articleId: article.id))
    }

    var body: some View {
        switch phase {
        case .picking:
            pickingView
        case .processing:
            processingView
        case .editing:
            editingView
        }
    }

    // MARK: - Phase: Picking

    private var pickingView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("Import Notebook Page")
                    .font(.title2.bold())
                Text("Choose a photo of your handwritten notes.\nVision will read your handwriting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Camera button
                CameraPickerButton { image in
                    sourceImage = image
                    Task { await process(image: image) }
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Add Notes")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    sourceImage = img
                    await process(image: img)
                } else {
                    errorMessage = "Couldn't load the selected photo."
                }
            }
        }
    }

    // MARK: - Phase: Processing

    private var processingView: some View {
        VStack(spacing: 24) {
            if let img = sourceImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Reading your handwriting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Processing")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Phase: Editing

    private var editingView: some View {
        VStack(spacing: 0) {
            // Photo strip at the top
            if let img = sourceImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxHeight: 180)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        // Confidence badge
                        if let conf = note.llmConfidence {
                            Label("\(Int(conf * 100))%", systemImage: "checkmark.seal.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(10)
                        }
                    }
            }

            Divider()

            // Factual issues banner
            if !note.factualIssues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("\(note.factualIssues.count) factual issue\(note.factualIssues.count == 1 ? "" : "s") flagged by AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.08))
            }

            // Editable markdown
            TextEditor(text: $markdownDraft)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        .navigationTitle("Edit Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard") { dismiss() }
                    .foregroundStyle(.red)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Processing

    @MainActor
    private func process(image: UIImage) async {
        phase = .processing
        errorMessage = nil

        guard let cgImage = image.cgImage else {
            errorMessage = "Couldn't read image data."
            phase = .picking
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
                markdownDraft = result.markdown
            } else {
                let fallback = "## Notes\n\n\(ocrText)"
                note.markdown = fallback
                markdownDraft = fallback
            }

            phase = .editing
        } catch {
            errorMessage = "Processing failed: \(error.localizedDescription)"
            phase = .picking
        }
    }

    private func save() {
        note.markdown = markdownDraft
        note.updatedAt = Date()
        appState.noteService.save(note)
        onSave?()
        dismiss()
    }
}

// MARK: - Camera picker

private struct CameraPickerButton<Label: View>: View {
    let onCapture: (UIImage) -> Void
    @ViewBuilder let label: () -> Label
    @State private var showCamera = false

    var body: some View {
        Button { showCamera = true } label: { label() }
            .sheet(isPresented: $showCamera) {
                CameraView(onCapture: { img in
                    showCamera = false
                    onCapture(img)
                })
                .ignoresSafeArea()
            }
    }
}

private struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onCapture(img) }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
