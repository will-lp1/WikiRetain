# WikiRetain

Read Wikipedia. Actually remember it.

An iOS app that pairs an **offline Wikipedia corpus** with spaced repetition
(FSRS), handwritten-note OCR, AI quizzes, and a knowledge graph.

## How the offline corpus works

The app needs a body of Wikipedia articles to read. Earlier this was a ~1.2 GB
`corpus.db` you had to download from a GitHub Release on first launch — which
meant the app didn't work out of the box and wasn't truly offline.

Now the corpus is **built into the app**:

1. `corpus_build/build_corpus.py` builds a compact SQLite corpus from Wikipedia's
   [Vital articles](https://en.wikipedia.org/wiki/Wikipedia:Vital_articles) — the
   encyclopedia's most important topics.
2. It's **gzip-compressed** to `corpus.db.gz`, which is small enough to commit to
   this repo (Level 3 ≈ 1,000 articles, a few MB compressed) and ship inside the
   app bundle.
3. On **first launch** the app inflates `corpus.db.gz` → `Documents/corpus.db`
   using a dependency-free gunzip built on Apple's `Compression` framework
   (`WikiRetain/Services/Gzip.swift`). No network, fully offline.

A larger corpus can still be downloaded or imported later (Settings → Corpus), and
it takes precedence over the bundled one.

```
build_corpus.py ──► corpus.db ──gzip──► corpus.db.gz ──commit──► app bundle
                                                          │
                                       first launch ◄─────┘
                                       Gzip.gunzip() ──► Documents/corpus.db
```

## Building the corpus

```bash
# Level 3 — ~1,000 vital articles (default; a few MB gzipped, fits in the repo)
python3 corpus_build/build_corpus.py

# Level 4 — ~10,000 vital articles (larger; check it stays under GitHub's 100 MB)
python3 corpus_build/build_corpus.py --level 4

# Quick smoke test
python3 corpus_build/build_corpus.py --limit 25
```

This writes `corpus_build/corpus.db` and `corpus_build/corpus.db.gz`.

## Installing the corpus into the app

```bash
./install_corpus.sh           # copies corpus_build/corpus.db.gz into the app + runs xcodegen
brew install xcodegen         # one-time, if you don't have it
```

Then open `WikiRetain.xcodeproj` and run. The bundled corpus is inflated on first
launch; subsequent launches reuse the inflated `corpus.db`.

## Corpus schema

`corpus.db` is read-only at runtime. User state (reading history, SRS cards,
notes, graph) lives in a separate `userdata.db` created by the app.

```sql
articles(id, title, body_html, category, wikilinks, word_count, vital_level)
articles_fts USING fts5(title, body_text, content='articles', content_rowid='id')
```

- `body_html` — HTML extract from the MediaWiki extracts API.
- `wikilinks` — JSON array of **internal** article ids (other rows this article
  links to), powering the "See Also" section and the knowledge graph.
- `articles_fts` — full-text search index over title + plain-text body.

## Requirements

- iOS 26, Xcode 16.4, Swift 6.2
- Python 3 (standard library only) to build the corpus
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) to regenerate the project
