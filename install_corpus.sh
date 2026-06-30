#!/usr/bin/env bash
# install_corpus.sh
# Installs the *gzipped* corpus into the Xcode project so it ships inside the app
# bundle and is inflated on first launch (fully offline — no download step).
#
# Usage:
#   ./install_corpus.sh [path/to/corpus.db.gz]
#
# If no argument is given the script looks for corpus_build/corpus.db.gz
# (produced by:  python3 corpus_build/build_corpus.py).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
DEST_DIR="$PROJECT_DIR/WikiRetain"
DEFAULT_SRC="$SCRIPT_DIR/corpus_build/corpus.db.gz"

SOURCE="${1:-$DEFAULT_SRC}"

if [[ ! -f "$SOURCE" ]]; then
    echo "Error: corpus.db.gz not found at: $SOURCE"
    echo "Build it first with:  python3 corpus_build/build_corpus.py"
    exit 1
fi

DEST="$DEST_DIR/corpus.db.gz"

echo "Installing gzipped corpus..."
echo "  from: $SOURCE"
echo "    to: $DEST"
cp "$SOURCE" "$DEST"

SIZE=$(du -sh "$DEST" | awk '{print $1}')
echo "  size: $SIZE"

# GitHub rejects files larger than 100 MB on a normal push.
BYTES=$(wc -c < "$DEST")
if (( BYTES > 99 * 1024 * 1024 )); then
    echo ""
    echo "WARNING: corpus.db.gz is ${SIZE} — over GitHub's 100 MB file limit."
    echo "Rebuild with a lower level:  python3 corpus_build/build_corpus.py --level 3"
fi

# Regenerate the Xcode project so corpus.db.gz is registered as a bundle resource.
if command -v xcodegen &>/dev/null; then
    echo ""
    echo "Running xcodegen..."
    cd "$PROJECT_DIR"
    xcodegen generate
    echo "xcodegen complete."
else
    echo ""
    echo "Warning: xcodegen not found in PATH. Install it with:"
    echo "  brew install xcodegen"
    echo "Then re-run this script, or manually add corpus.db.gz to the Xcode project."
fi

echo ""
echo "Done. corpus.db.gz ($SIZE) is installed at:"
echo "  $DEST"
echo "It will be inflated to corpus.db on first launch — the app is now fully offline."
