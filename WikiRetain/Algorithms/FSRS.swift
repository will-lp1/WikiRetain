import Foundation

/// FSRS-4.5 implementation in Swift.
/// Reference: https://github.com/open-spaced-repetition/fsrs4anki
enum FSRS {
    // MARK: - Constants
    static let decayConstant: Double = -0.5
    static let factor: Double = pow(0.9, 1.0 / decayConstant) - 1   // ≈ 19/81

    // MARK: - Core schedule

    static func schedule(card: SRSCard, rating: RecallRating, now: Date = Date()) -> SRSCard {
        var updated = card
        let w = card.fsrsParams?.w ?? FSRSParams.defaultWeights.w
        let elapsed = max(0, now.timeIntervalSince(card.lastReview ?? now) / 86400)

        updated.elapsedDays = Int(elapsed)
        updated.lastReview = now

        switch card.state {
        case .new:
            updated = scheduleNew(card: updated, rating: rating, w: w, now: now)
        case .learning, .relearning:
            updated = scheduleLearning(card: updated, rating: rating, w: w, now: now)
        case .review:
            updated = scheduleReview(card: updated, rating: rating, w: w, elapsed: elapsed, now: now)
        }

        return updated
    }

    // MARK: - State handlers

    private static func scheduleNew(card: SRSCard, rating: RecallRating, w: [Double], now: Date) -> SRSCard {
        var c = card
        c.state = .learning
        c.reps = 1

        switch rating {
        case .again:
            c.difficulty = initDifficulty(rating: rating, w: w)
            c.stability = w[0]
            c.scheduledDays = 1
        case .hard:
            c.difficulty = initDifficulty(rating: rating, w: w)
            c.stability = w[1]
            c.scheduledDays = 3
        case .good:
            c.difficulty = initDifficulty(rating: rating, w: w)
            c.stability = w[2]
            c.scheduledDays = 4
        case .easy:
            c.difficulty = initDifficulty(rating: rating, w: w)
            c.stability = w[3]
            c.state = .review
            c.scheduledDays = 7
        }

        c.dueDate = Calendar.current.date(byAdding: .day, value: c.scheduledDays, to: now) ?? now
        return c
    }

    private static func scheduleLearning(card: SRSCard, rating: RecallRating, w: [Double], now: Date) -> SRSCard {
        var c = card
        c.reps += 1

        switch rating {
        case .again:
            c.lapses += 1
            c.state = .relearning
            c.stability = forgettingStability(stability: c.stability, w: w)
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.scheduledDays = 1
        case .hard:
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.scheduledDays = max(2, c.scheduledDays)
        case .good:
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.stability = shortTermStability(stability: c.stability, w: w)
            c.state = .review
            c.scheduledDays = max(4, Int(c.stability))
        case .easy:
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.stability = shortTermStability(stability: c.stability, w: w) * w[7]
            c.state = .review
            c.scheduledDays = max(7, Int(c.stability * 2))
        }

        c.dueDate = Calendar.current.date(byAdding: .day, value: c.scheduledDays, to: now) ?? now
        return c
    }

    private static func scheduleReview(card: SRSCard, rating: RecallRating, w: [Double], elapsed: Double, now: Date) -> SRSCard {
        var c = card
        c.reps += 1

        let r = retrievability(stability: c.stability, elapsed: elapsed)

        switch rating {
        case .again:
            c.lapses += 1
            c.state = .relearning
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.stability = forgettingStability(stability: c.stability, w: w)
            c.scheduledDays = 1
        case .hard:
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.stability = nextStability(d: c.difficulty, s: c.stability, r: r, rating: rating, w: w)
            c.scheduledDays = max(c.scheduledDays + 1, Int(c.stability * 1.0))
        case .good:
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.stability = nextStability(d: c.difficulty, s: c.stability, r: r, rating: rating, w: w)
            c.scheduledDays = max(c.scheduledDays + 2, Int(c.stability))
        case .easy:
            c.difficulty = nextDifficulty(d: c.difficulty, rating: rating, w: w)
            c.stability = nextStability(d: c.difficulty, s: c.stability, r: r, rating: rating, w: w)
            c.scheduledDays = max(c.scheduledDays + 4, Int(c.stability * 1.3))
        }

        c.state = .review
        c.dueDate = Calendar.current.date(byAdding: .day, value: c.scheduledDays, to: now) ?? now
        return c
    }

    // MARK: - Memory formulas

    /// Retrievability: R(t) = (1 + factor * t/S)^decay
    static func retrievability(stability: Double, elapsed: Double) -> Double {
        pow(1.0 + factor * elapsed / max(stability, 0.01), decayConstant)
    }

    private static func initDifficulty(rating: RecallRating, w: [Double]) -> Double {
        let base = w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1
        return clampDifficulty(base)
    }

    private static func nextDifficulty(d: Double, rating: RecallRating, w: [Double]) -> Double {
        let delta = -w[6] * Double(rating.rawValue - 3)
        let dd = d + delta * ((10 - d) / 9)
        return clampDifficulty(dd)
    }

    private static func nextStability(d: Double, s: Double, r: Double, rating: RecallRating, w: [Double]) -> Double {
        let hardPenalty: Double = rating == .hard ? w[15] : 1.0
        let easyBonus: Double  = rating == .easy ? w[16] : 1.0
        let base = w[8] * pow(d, -w[9]) * (pow(s + 1, w[10]) - 1) * exp((1 - r) * w[11])
        return max(s * base * hardPenalty * easyBonus, 0.01)
    }

    private static func shortTermStability(stability: Double, w: [Double]) -> Double {
        max(stability * w[7], 0.01)
    }

    private static func forgettingStability(stability: Double, w: [Double]) -> Double {
        max(w[12] * pow(stability, -w[13]) * (exp((1 - 0.0) * w[14]) - 1), 0.01)
    }

    private static func clampDifficulty(_ d: Double) -> Double {
        min(max(d, 1.0), 10.0)
    }

    // MARK: - Due-date preview

    static func previewIntervals(card: SRSCard) -> [RecallRating: Int] {
        var result: [RecallRating: Int] = [:]
        for rating in RecallRating.allCases {
            let scheduled = schedule(card: card, rating: rating)
            result[rating] = scheduled.scheduledDays
        }
        return result
    }
}
