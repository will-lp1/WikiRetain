#!/usr/bin/env python3
"""
build_corpus.py — Build WikiRetain's offline Wikipedia corpus.

Produces a self-contained SQLite database (``corpus.db``) that the iOS app reads
read-only, plus a gzip-compressed ``corpus.db.gz`` that is small enough to commit
to the GitHub repo and ship *inside the app bundle* (decompressed on first launch
— so the app works fully offline with no download step).

The corpus is sourced from Wikipedia's "Vital articles" — a hand-curated list of
the encyclopedia's most important topics. Level 3 is ~1,000 articles (a few MB
gzipped); Level 4 is ~10,000.

Schema (must match Services/DatabaseService.swift + ArticleService.swift):

    articles(id, title, body_html, category, wikilinks, word_count, vital_level)
    articles_fts USING fts5(title, body_text, content='articles', content_rowid='id')

  - body_html : cleaned article HTML from the MediaWiki parse API, preserving
                inline <a href="/wiki/Title"> links and formatting (prose,
                headings, lists, emphasis); tables/refs/images/chrome stripped.
  - wikilinks : JSON array of *internal* article ids (ids of other rows in this
                corpus that this article links to) — used for the "See Also"
                graph and the knowledge map.

Usage:
    python3 corpus_build/build_corpus.py                 # Level 3 (~1000 articles)
    python3 corpus_build/build_corpus.py --level 4       # Level 4 (~10000)
    python3 corpus_build/build_corpus.py --limit 50      # quick test build
    python3 corpus_build/build_corpus.py --out /tmp/corpus.db

After it finishes, run ./install_corpus.sh to copy corpus.db.gz into the app.
"""

from __future__ import annotations

import argparse
import gzip
import html
import json
import os
import re
import shutil
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from html.parser import HTMLParser

WORKERS = 2  # concurrent API requests — Wikimedia rate-limits anonymous bots hard

API = "https://en.wikipedia.org/w/api.php"
USER_AGENT = "WikiRetainCorpusBuilder/1.0 (https://github.com/will-lp1/WikiRetain)"

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


_throttle = threading.Semaphore(WORKERS)  # hard cap on in-flight requests


def api_get(params: dict, retries: int = 6) -> dict:
    """GET the MediaWiki API with JSON output and 429-aware exponential backoff."""
    params = {**params, "format": "json", "formatversion": "1"}
    url = API + "?" + urllib.parse.urlencode(params)
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            with _throttle:
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 429:
                # Respect Retry-After when present, else back off aggressively.
                retry_after = e.headers.get("Retry-After")
                wait = float(retry_after) if retry_after and retry_after.isdigit() else 5.0 * (attempt + 1)
                time.sleep(wait)
            else:
                time.sleep(1.5 * (attempt + 1))
        except Exception as e:  # noqa: BLE001 - network is flaky, retry anything
            last_err = e
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"API request failed after {retries} tries: {last_err}\n{url}")


def chunked(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i : i + n]


# ---------------------------------------------------------------------------
# Step 1 — fetch the vital-articles list, grouped by section (= category)
# ---------------------------------------------------------------------------

# Skip these pseudo-sections so they don't become categories.
_SKIP_SECTIONS = {"current total", "contents", "see also", "notes", "references"}

# Match [[Target]] / [[Target|Display]] wikilinks, excluding namespaced links
# (File:, Wikipedia:, Category:, etc. all contain a ':' before the title).
_LINK_RE = re.compile(r"\[\[([^\[\]|#:]+?)(?:\|[^\[\]]*?)?\]\]")
_HEADER_RE = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.M)


def fetch_vital_list(level: int) -> list[tuple[str, str]]:
    """Return an ordered, de-duplicated list of (title, category) for a level."""
    page = f"Wikipedia:Vital articles/Level {level}"
    data = api_get({"action": "parse", "page": page, "prop": "wikitext", "redirects": "1"})
    if "parse" not in data:
        raise RuntimeError(f"Could not load vital-articles page '{page}': {data}")
    wikitext = data["parse"]["wikitext"]["*"]

    # Walk the wikitext, tracking the current top-level (== ==) section as the
    # category, and collect mainspace [[links]] beneath it.
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    category = "General"

    # Build an index of header positions so we can attribute each link to the
    # nearest preceding level-2 header.
    headers = [(m.start(), len(m.group(1)), m.group(2).strip()) for m in _HEADER_RE.finditer(wikitext)]

    def category_at(pos: int) -> str:
        cat = "General"
        for start, depth, name in headers:
            if start > pos:
                break
            if depth == 2 and name.strip().lower() not in _SKIP_SECTIONS:
                cat = name.strip()
        return cat

    for m in _LINK_RE.finditer(wikitext):
        title = html.unescape(m.group(1).strip())
        if not title or title.startswith(("File:", "Image:")):
            continue
        key = title.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append((title, category_at(m.start())))

    return out


# ---------------------------------------------------------------------------
# Step 2 — resolve titles (follow redirects / normalisation) and assign ids
# ---------------------------------------------------------------------------


def resolve_titles(titles: list[str]) -> dict[str, str]:
    """Map each requested title -> canonical Wikipedia title."""
    mapping: dict[str, str] = {}
    for batch in chunked(titles, 50):
        data = api_get(
            {
                "action": "query",
                "titles": "|".join(batch),
                "redirects": "1",
            }
        )
        q = data.get("query", {})
        # normalized: requested-casing -> normalized title
        norm = {n["from"]: n["to"] for n in q.get("normalized", [])}
        # redirects: normalized title -> target title
        redir = {r["from"]: r["to"] for r in q.get("redirects", [])}
        for t in batch:
            step = norm.get(t, t)
            step = redir.get(step, step)
            mapping[t] = step
        time.sleep(0.1)
    return mapping


# ---------------------------------------------------------------------------
# Step 3 — fetch HTML extracts
# ---------------------------------------------------------------------------

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


def strip_html(s: str) -> str:
    return _WS_RE.sub(" ", html.unescape(_TAG_RE.sub(" ", s))).strip()


# --- HTML cleaner: turn full Parsoid/parse HTML into compact, link-rich prose ---
#
# The `extracts` API strips inline links and most markup, so we use `action=parse`
# (full rendered HTML) and clean it down to a whitelist. We KEEP prose, headings,
# lists, emphasis, and inline `<a href="/wiki/Title">` links (which the app turns
# into tappable navigation). We DROP tables/infoboxes, images, references,
# navboxes, citation superscripts, edit links, and other chrome to keep it small.

_KEEP_TAGS = {"p", "a", "b", "strong", "i", "em", "ul", "ol", "li",
              "dl", "dt", "dd", "blockquote", "br", "sup", "sub"}  # sup/sub for math (E=mc², H₂O)
_HEADING_TAGS = {"h2", "h3", "h4", "h5"}
# Note: citation markers (<sup class="reference">) are still dropped via _SKIP_CLASS.
_SKIP_TAGS = {"style", "link", "script", "img", "figure", "figcaption", "table",
              "math", "audio", "video", "map", "meta", "noscript"}
_SKIP_CLASS = ("navbox", "editsection", "reference", "reflist", "mw-references",
               "metadata", "shortdescription", "hatnote", "thumb", "gallery",
               "infobox", "ambox", "navigation", "noprint", "mw-empty-elt", "toc",
               "sistersitebox", "mbox", "navbar")
# Section headings whose content (to the next section/end) is dropped wholesale.
_CUT_SECTIONS = {"references", "notes", "citations", "sources", "bibliography",
                 "external links", "further reading", "footnotes", "works cited",
                 "explanatory notes", "general sources", "see also"}
_VOID_TAGS = {"br", "img", "link", "meta", "hr"}


class _HTMLCleaner(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.skip_tag: str | None = None
        self.skip_n = 0
        self.suppress = False          # set once we hit a cut section heading
        self.head_tag: str | None = None
        self.head_buf: list[str] = []
        self.a_stack: list[bool] = []  # whether each open <a> was emitted

    def _is_skip(self, tag: str, attrs) -> bool:
        if tag in _SKIP_TAGS:
            return True
        d = dict(attrs)
        if d.get("role") == "navigation":
            return True
        cls = d.get("class", "") or ""
        return any(c in cls for c in _SKIP_CLASS)

    def handle_starttag(self, tag, attrs):
        if self.skip_tag:
            if tag == self.skip_tag and tag not in _VOID_TAGS:
                self.skip_n += 1
            return
        if self._is_skip(tag, attrs):
            if tag not in _VOID_TAGS:
                self.skip_tag, self.skip_n = tag, 1
            return
        if self.suppress:
            return
        if tag in _HEADING_TAGS:
            self.head_tag, self.head_buf = tag, []
            return
        if tag == "a":
            href = dict(attrs).get("href", "")
            href = href.split("#", 1)[0]  # drop section fragment so the app can match it
            # Keep only mainspace article links (drop Help:/File:/Wikipedia:/Category: etc.,
            # keeping their visible text). Mainspace titles don't contain a colon.
            target = href[6:] if href.startswith("/wiki/") else ""
            if target and ":" not in target and '"' not in href:
                self.out.append('<a href="%s">' % href)
                self.a_stack.append(True)
            else:
                self.a_stack.append(False)  # drop the anchor, keep its text
            return
        if tag in _KEEP_TAGS:
            self.out.append("<br>" if tag == "br" else "<%s>" % tag)

    def handle_endtag(self, tag):
        if self.skip_tag:
            if tag == self.skip_tag:
                self.skip_n -= 1
                if self.skip_n <= 0:
                    self.skip_tag = None
            return
        if self.head_tag and tag == self.head_tag:
            raw = "".join(self.head_buf).strip()
            if raw.lower() in _CUT_SECTIONS:
                self.suppress = True
            elif raw and not self.suppress:
                self.out.append("<%s>%s</%s>" % (tag, html.escape(raw, quote=False), tag))
            self.head_tag, self.head_buf = None, []
            return
        if self.suppress:
            return
        if tag == "a":
            if self.a_stack and self.a_stack.pop():
                self.out.append("</a>")
            return
        if tag in _KEEP_TAGS and tag != "br":
            self.out.append("</%s>" % tag)

    def handle_data(self, data):
        if self.skip_tag or self.suppress:
            return
        if self.head_tag is not None:
            self.head_buf.append(data)
            return
        self.out.append(html.escape(data, quote=False))

    def result(self) -> str:
        h = "".join(self.out)
        h = re.sub(r"<p>\s*</p>", "", h)
        h = re.sub(r"\n{2,}", "\n", h)
        h = re.sub(r"[ \t]{2,}", " ", h)
        return h.strip()


def clean_article_html(raw: str) -> str:
    c = _HTMLCleaner()
    c.feed(raw)
    return c.result()


def _fetch_one_extract(title: str) -> tuple[str, str]:
    """Fetch full rendered article HTML and clean it to link-rich prose.

    Uses `action=parse` (which preserves inline links and formatting), one title
    per request, parallelised across a thread pool.
    """
    data = api_get(
        {
            "action": "parse",
            "page": title,
            "prop": "text",
            "redirects": "1",
            "disableeditsection": "1",
            "disabletoc": "1",
        }
    )
    parse = data.get("parse")
    if not parse or "text" not in parse:
        return title, ""
    canonical = parse.get("title", title)
    cleaned = clean_article_html(parse["text"]["*"])
    return canonical, cleaned


def fetch_extracts(canonical_titles: list[str]) -> dict[str, str]:
    """canonical title -> cleaned article HTML, fetched concurrently (one per request)."""
    extracts: dict[str, str] = {}
    total = len(canonical_titles)
    done = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futures = {ex.submit(_fetch_one_extract, t): t for t in canonical_titles}
        for fut in as_completed(futures):
            try:
                title, body = fut.result()
                if body:
                    extracts[title] = body
            except Exception as e:  # noqa: BLE001 - skip a failing article, keep going
                print(f"\n  skip article '{futures[fut]}': {e}")
            done += 1
            print(f"  articles {done}/{total}", end="\r", flush=True)
    print()
    return extracts


# ---------------------------------------------------------------------------
# Step 4 — fetch outgoing links (for the internal wikilink graph)
# ---------------------------------------------------------------------------


def _fetch_one_links(title: str) -> tuple[str, list[str]]:
    """Fetch all mainspace link targets for a single article (with continuation)."""
    out: list[str] = []
    canonical = title
    cont: dict = {}
    while True:
        data = api_get(
            {
                "action": "query",
                "prop": "links",
                "plnamespace": "0",
                "pllimit": "max",
                "redirects": "1",
                "titles": title,
                **cont,
            }
        )
        pages = data.get("query", {}).get("pages", {})
        for p in pages.values():
            canonical = p.get("title", title)
            for l in p.get("links", []):
                out.append(l["title"])
        if "continue" in data:
            cont = data["continue"]
        else:
            break
    return canonical, out


def fetch_links(canonical_titles: list[str]) -> dict[str, list[str]]:
    """canonical title -> list of mainspace link target titles (concurrent)."""
    links: dict[str, list[str]] = {}
    total = len(canonical_titles)
    done = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futures = {ex.submit(_fetch_one_links, t): t for t in canonical_titles}
        for fut in as_completed(futures):
            try:
                title, targets = fut.result()
                links[title] = targets
            except Exception as e:  # noqa: BLE001 - links are best-effort
                print(f"\n  skip links '{futures[fut]}': {e}")
            done += 1
            print(f"  links {done}/{total}", end="\r", flush=True)
    print()
    return links


# ---------------------------------------------------------------------------
# Build the database
# ---------------------------------------------------------------------------


def build_db(out_path: str, articles: list[dict]) -> None:
    if os.path.exists(out_path):
        os.remove(out_path)
    conn = sqlite3.connect(out_path)
    conn.executescript(
        """
        PRAGMA journal_mode=DELETE;
        CREATE TABLE articles (
            id          INTEGER PRIMARY KEY,
            title       TEXT    NOT NULL,
            body_html   TEXT    NOT NULL,
            category    TEXT,
            wikilinks   TEXT,
            word_count  INTEGER,
            vital_level INTEGER
        );
        CREATE VIRTUAL TABLE articles_fts USING fts5(
            title, body_text,
            content='articles', content_rowid='id'
        );
        CREATE INDEX idx_articles_title ON articles(title);
        """
    )
    for a in articles:
        conn.execute(
            "INSERT INTO articles(id,title,body_html,category,wikilinks,word_count,vital_level)"
            " VALUES(?,?,?,?,?,?,?)",
            (
                a["id"],
                a["title"],
                a["body_html"],
                a["category"],
                json.dumps(a["wikilinks"]),
                a["word_count"],
                a["vital_level"],
            ),
        )
        conn.execute(
            "INSERT INTO articles_fts(rowid,title,body_text) VALUES(?,?,?)",
            (a["id"], a["title"], a["body_text"]),
        )
    conn.commit()
    conn.execute("INSERT INTO articles_fts(articles_fts) VALUES('optimize')")
    conn.commit()
    conn.execute("VACUUM")
    conn.commit()
    conn.close()


def gzip_file(src: str, dst: str) -> None:
    with open(src, "rb") as f_in, gzip.open(dst, "wb", compresslevel=9) as f_out:
        shutil.copyfileobj(f_in, f_out)


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the WikiRetain offline corpus.")
    ap.add_argument("--level", type=int, default=3, help="Vital-articles level (3=~1k, 4=~10k)")
    ap.add_argument("--limit", type=int, default=0, help="Cap article count (0 = all) — for quick tests")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "corpus.db"))
    args = ap.parse_args()

    print(f"Fetching Vital articles Level {args.level} list…")
    vital = fetch_vital_list(args.level)
    if args.limit:
        vital = vital[: args.limit]
    print(f"  {len(vital)} candidate articles")

    requested_titles = [t for t, _ in vital]
    cat_by_requested = {t: c for t, c in vital}

    print("Resolving redirects / normalisation…")
    canon = resolve_titles(requested_titles)

    # Canonical title -> category (first writer wins), preserving list order.
    canon_order: list[str] = []
    cat_by_canon: dict[str, str] = {}
    for t in requested_titles:
        c = canon[t]
        if c not in cat_by_canon:
            cat_by_canon[c] = cat_by_requested[t]
            canon_order.append(c)
    print(f"  {len(canon_order)} unique articles after redirect collapse")

    print("Fetching & cleaning article HTML…")
    extracts = fetch_extracts(canon_order)

    print("Fetching link graph…")
    raw_links = fetch_links(canon_order)

    # Assign ids only to articles that actually have content.
    id_by_canon: dict[str, int] = {}
    final_titles: list[str] = []
    for t in canon_order:
        if extracts.get(t):
            id_by_canon[t] = len(final_titles) + 1
            final_titles.append(t)
    print(f"  {len(final_titles)} articles have extracts")

    articles: list[dict] = []
    for t in final_titles:
        aid = id_by_canon[t]
        body_html = extracts[t]
        body_text = strip_html(body_html)
        # Internal wikilinks: keep only targets that exist in this corpus.
        targets = raw_links.get(t, [])
        link_ids = []
        seen_ids = set()
        for tgt in targets:
            tid = id_by_canon.get(tgt)
            if tid and tid != aid and tid not in seen_ids:
                seen_ids.add(tid)
                link_ids.append(tid)
        articles.append(
            {
                "id": aid,
                "title": t,
                "body_html": body_html,
                "body_text": body_text,
                "category": cat_by_canon.get(t, "General"),
                "wikilinks": link_ids,
                "word_count": len(body_text.split()),
                "vital_level": args.level,
            }
        )

    print(f"Writing database → {args.out}")
    build_db(args.out, articles)
    db_size = os.path.getsize(args.out)

    gz_path = args.out + ".gz"
    print(f"Compressing → {gz_path}")
    gzip_file(args.out, gz_path)
    gz_size = os.path.getsize(gz_path)

    total_links = sum(len(a["wikilinks"]) for a in articles)
    print("\nDone.")
    print(f"  articles    : {len(articles)}")
    print(f"  link edges  : {total_links}")
    print(f"  corpus.db   : {human(db_size)}")
    print(f"  corpus.db.gz: {human(gz_size)}  ({100 * gz_size / db_size:.0f}% of original)")
    if gz_size > 95 * 1024 * 1024:
        print("  WARNING: corpus.db.gz exceeds GitHub's 100 MB file limit — use a lower --level.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
