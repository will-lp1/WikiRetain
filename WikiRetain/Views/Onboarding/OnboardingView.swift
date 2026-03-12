import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var step: Step = .welcome

    enum Step { case welcome, aiCheck, corpus }

    var body: some View {
        NavigationStack {
            switch step {
            case .welcome:
                WelcomeStep(onNext: { step = .aiCheck })
            case .aiCheck:
                AICheckStep(aiAvailable: appState.aiAvailable, onNext: { step = .corpus })
            case .corpus:
                CorpusStep(onComplete: { request in
                    appState.corpusResourceRequest = request
                    appState.corpusArticleCount = appState.db.corpusArticleCount
                    appState.hasCorpus = appState.corpusArticleCount > 0
                })
            }
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
            VStack(spacing: 12) {
                Text("WikiRetain")
                    .font(.largeTitle.bold())
                Text("Read Wikipedia. Actually remember it.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "book.fill", color: .blue, title: "50,000 Articles Offline",
                           subtitle: "Wikipedia's most important articles, always available")
                FeatureRow(icon: "pencil.and.outline", color: .green, title: "Handwritten Notes",
                           subtitle: "OCR + AI converts your ink to searchable Markdown")
                FeatureRow(icon: "arrow.clockwise.heart.fill", color: .orange, title: "Spaced Repetition",
                           subtitle: "FSRS-4.5 resurfaces articles when you're about to forget")
                FeatureRow(icon: "network", color: .purple, title: "Knowledge Graph",
                           subtitle: "See how your knowledge connects and where the gaps are")
            }
            .padding(.horizontal)
            Spacer()
            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AI Check

private struct AICheckStep: View {
    let aiAvailable: Bool
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: aiAvailable ? "checkmark.seal.fill" : "info.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(aiAvailable ? .green : .orange)
            VStack(spacing: 12) {
                Text(aiAvailable ? "Apple Intelligence Ready" : "Apple Intelligence Not Enabled")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(aiAvailable
                     ? "Quiz generation, note validation, and smart search are all ready."
                     : "For the full experience, enable Apple Intelligence in Settings. Reading, search, and spaced repetition work without it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if !aiAvailable {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline)
            }
            Spacer()
            Button(action: onNext) {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }
}

// MARK: - Corpus

private struct CorpusStep: View {
    @EnvironmentObject var appState: AppState
    let onComplete: (NSBundleResourceRequest?) -> Void

    @State private var phase: Phase = .idle
    @State private var progress: Double = 0
    @State private var errorMsg: String?
    @State private var showFilePicker = false
    @State private var downloadTask: Task<Void, Never>?

    enum Phase { case idle, downloading, importing, done }

    private var hasDownloadURL: Bool { Config.corpusDownloadURL != nil }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 10) {
                Text("Wikipedia Corpus")
                    .font(.title2.bold())
                Text("9,978 vital Wikipedia articles, fully offline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Progress
            if phase == .downloading {
                VStack(spacing: 8) {
                    ProgressView(value: progress > 0 ? progress : nil)
                        .padding(.horizontal)
                    Text(progress > 0 ? "\(Int(progress * 100))%" : "Connecting…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") {
                        downloadTask?.cancel()
                        phase = .idle; progress = 0
                    }
                    .font(.caption).foregroundStyle(.red)
                }
            } else if phase == .importing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Importing…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let errorMsg {
                Text(errorMsg).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                // Primary: URL download (GitHub Releases, etc.)
                if hasDownloadURL {
                    Button(action: startURLDownload) {
                        Label(phase == .downloading ? "Downloading…" : "Download Corpus",
                              systemImage: "arrow.down.circle.fill")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding()
                            .background(phase == .idle ? Color.blue : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(phase != .idle)
                }

                // Import from Files (always available)
                if hasDownloadURL {
                    Button(action: { showFilePicker = true }) {
                        Label("Import corpus.db from Files", systemImage: "folder.badge.plus")
                            .font(.subheadline).foregroundStyle(.blue)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(phase != .idle)
                } else {
                    Button(action: { showFilePicker = true }) {
                        Label("Import corpus.db from Files", systemImage: "folder.badge.plus")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding()
                            .background(phase == .idle ? Color.blue : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(phase != .idle)
                }
            }
            .padding(.horizontal).padding(.bottom)
        }
        .padding()
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "db") ?? .data,
                                  UTType(filenameExtension: "sqlite") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private func startURLDownload() {
        guard let url = Config.corpusDownloadURL else { return }
        phase = .downloading
        progress = 0
        errorMsg = nil
        downloadTask = Task {
            do {
                try await appState.db.downloadCorpus(from: url) { p in
                    Task { @MainActor in self.progress = p }
                }
                appState.corpusArticleCount = appState.db.corpusArticleCount
                appState.hasCorpus = appState.corpusArticleCount > 0
                phase = .done
                onComplete(nil)
            } catch is CancellationError {
                phase = .idle; progress = 0
            } catch {
                phase = .idle
                errorMsg = error.localizedDescription
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMsg = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            phase = .importing
            errorMsg = nil
            Task {
                do {
                    try appState.db.importCorpus(from: url)
                    appState.corpusArticleCount = appState.db.corpusArticleCount
                    appState.hasCorpus = appState.corpusArticleCount > 0
                    phase = .done
                    onComplete(nil)
                } catch {
                    phase = .idle
                    errorMsg = error.localizedDescription
                }
            }
        }
    }
}
