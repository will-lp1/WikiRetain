import Foundation

extension DatabaseService {
    /// Returns `true` when the bundled corpus contains more than 100 articles,
    /// indicating it is the real corpus rather than the small dev placeholder.
    func corpusIsReady() -> Bool {
        corpusArticleCount > 100
    }
}
