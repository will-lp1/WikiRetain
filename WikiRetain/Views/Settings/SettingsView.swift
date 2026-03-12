import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("targetRetention") private var targetRetention: Double = 0.9
    @AppStorage("dailyReviewLimit") private var dailyReviewLimit: Int = 20
    @AppStorage("newCardsPerDay") private var newCardsPerDay: Int = 5
    @AppStorage("interleavingEnabled") private var interleavingEnabled: Bool = true
    @AppStorage("fontSizeOffset") private var fontSizeOffset: Int = 0
    @AppStorage("colorScheme") private var colorScheme: String = "system"
    @State private var notificationsEnabled = false
    @State private var stats: ReviewService.ReviewStats?
    @State private var showCorpusImporter = false
    @State private var corpusImporting = false
    @State private var corpusImportError: String?

    var body: some View {
        NavigationStack {
            List {
                // AI status
                Section("Apple Intelligence") {
                    HStack {
                        Label("Status", systemImage: "brain.head.profile")
                        Spacer()
                        Text(appState.aiAvailable ? "Available" : "Not enabled")
                            .foregroundStyle(appState.aiAvailable ? .green : .orange)
                    }
                    if !appState.aiAvailable {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .foregroundStyle(.blue)
                    }
                }

                // Retention
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Target Retention")
                            Spacer()
                            Text("\(Int(targetRetention * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $targetRetention, in: 0.7...0.97, step: 0.05)
                            .tint(.orange)
                        HStack {
                            Text("Relaxed (80%)").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("Mastery (95%)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Spaced Repetition")
                } footer: {
                    Text("Higher retention = more review sessions. Optimal range: 80–90%.")
                }

                Section {
                    Stepper("Daily limit: \(dailyReviewLimit)", value: $dailyReviewLimit, in: 5...100, step: 5)
                    Stepper("New per day: \(newCardsPerDay)", value: $newCardsPerDay, in: 1...20)
                    Toggle("Interleave categories", isOn: $interleavingEnabled)
                }

                // Reading
                Section("Reading") {
                    Picker("Appearance", selection: $colorScheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                        Text("Sepia").tag("sepia")
                    }
                    Stepper("Font size: \(fontSizeOffset > 0 ? "+\(fontSizeOffset)" : "\(fontSizeOffset)")",
                            value: $fontSizeOffset, in: -3...6)
                }

                // Notifications
                Section("Notifications") {
                    Toggle("Daily review reminder", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, enabled in
                            if enabled { requestNotifications() }
                        }
                }

                // Stats
                if let stats {
                    Section("Your Statistics") {
                        StatRow2(label: "Total reviewed", value: "\(stats.totalReviewed)")
                        StatRow2(label: "Retention rate", value: "\(Int(stats.retentionRate * 100))%")
                        StatRow2(label: "Current streak", value: "\(stats.streak) days")
                        StatRow2(label: "Corpus retained", value: "\(Int(stats.corpusRetained * 100))%")
                    }
                }

                // Corpus
                Section("Corpus") {
                    LabeledContent("Articles", value: "\(appState.corpusArticleCount.formatted())")
                    if corpusImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Importing…").foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            showCorpusImporter = true
                        } label: {
                            Label("Import corpus.db from Files", systemImage: "folder.badge.plus")
                        }
                    }
                    if let err = corpusImportError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                // About
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Corpus", value: "\(appState.corpusArticleCount.formatted()) articles")
                    LabeledContent("Algorithm", value: "FSRS-4.5")
                    LabeledContent("AI", value: appState.aiAvailable ? "Foundation Models ✓" : "Not available")
                    Link("Privacy — Zero telemetry", destination: URL(string: "https://en.wikipedia.org/wiki/Wikipedia:Privacy_policy")!)
                }
            }
            .navigationTitle("Settings")
            .task {
                stats = appState.reviewService.stats()
                notificationsEnabled = await checkNotificationStatus()
            }
            .fileImporter(
                isPresented: $showCorpusImporter,
                allowedContentTypes: [UTType(filenameExtension: "db") ?? .data,
                                      UTType(filenameExtension: "sqlite") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleCorpusImport(result)
            }
        }
    }

    private func handleCorpusImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            corpusImportError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            corpusImporting = true
            corpusImportError = nil
            Task {
                do {
                    try appState.db.importCorpus(from: url)
                    appState.corpusArticleCount = appState.db.corpusArticleCount
                    appState.hasCorpus = appState.corpusArticleCount > 0
                    corpusImporting = false
                } catch {
                    corpusImporting = false
                    corpusImportError = error.localizedDescription
                }
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notificationsEnabled = granted
                if granted { scheduleNotification() }
            }
        }
    }

    private func checkNotificationStatus() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    private func scheduleNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let content = UNMutableNotificationContent()
        content.title = "WikiRetain"
        content.body = "Articles are ready for review."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "daily-review", content: content, trigger: trigger)
        center.add(request)
    }
}

private struct StatRow2: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold()
        }
    }
}
