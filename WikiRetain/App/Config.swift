import Foundation

enum Config {
    /// Optional larger corpus. The app already ships a corpus inside its bundle
    /// (inflated on first launch — see DatabaseService.extractBundledCorpusIfNeeded),
    /// so this download is only an *upgrade* path for a bigger library and may be nil.
    /// The target may be a raw `.db` or a gzipped `.db.gz`; both are handled
    /// transparently on import (DatabaseService.installCorpusFile).
    static let corpusDownloadURL: URL? = URL(string: "https://github.com/will-lp1/WikiRetain/releases/download/v1.0/corpus.db.gz")
}
