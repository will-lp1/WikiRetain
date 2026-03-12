import Foundation

struct SRSCard: Identifiable, Codable {
    let articleId: Int64
    var dueDate: Date
    var stability: Double       // S: days for R to decay 100%→90%
    var difficulty: Double      // D: 1.0–10.0
    var elapsedDays: Int
    var scheduledDays: Int
    var reps: Int
    var lapses: Int
    var state: CardState
    var lastReview: Date?
    var fsrsParams: FSRSParams?

    var id: Int64 { articleId }

    enum CardState: Int, Codable {
        case new = 0
        case learning = 1
        case review = 2
        case relearning = 3
    }

    var isDue: Bool {
        dueDate <= Date()
    }

    var daysOverdue: Int {
        max(0, Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0)
    }

    init(articleId: Int64) {
        self.articleId = articleId
        self.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        self.stability = 1.0
        self.difficulty = 5.0
        self.elapsedDays = 0
        self.scheduledDays = 1
        self.reps = 0
        self.lapses = 0
        self.state = .new
    }
}

struct FSRSParams: Codable {
    // 17-weight FSRS-4.5 parameter vector
    var w: [Double]

    static var defaultWeights: FSRSParams {
        FSRSParams(w: [
            0.4072, 1.1829, 3.1262, 15.4722,
            7.2102, 0.5316, 1.0651, 0.0589,
            1.5330, 0.1544, 1.0070, 1.9395,
            0.1100, 0.2900, 2.2700, 0.0700,
            2.9898
        ])
    }
}

enum RecallRating: Int, Codable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var label: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }

    var color: String {
        switch self {
        case .again: "red"
        case .hard: "orange"
        case .good: "green"
        case .easy: "blue"
        }
    }

    var description: String {
        switch self {
        case .again: "Forgot — couldn't recall"
        case .hard:  "Recalled with effort"
        case .good:  "Recalled correctly"
        case .easy:  "Perfect recall, no effort"
        }
    }
}
