#!/usr/bin/env bash
# install_corpus.sh
# Copies corpus.db built by corpus_build/build_corpus.py into the Xcode project,
# runs xcodegen to register it, then reports the file size.
#
# Usage:
#   ./install_corpus.sh [path/to/corpus.db]
#
# If no argument is provided the script looks for corpus.db in ../corpus_build/
# (i.e. the sibling corpus_build directory relative to this script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
DEST_DIR="$PROJECT_DIR/WikiRetain"
DEFAULT_SRC="$SCRIPT_DIR/../corpus_build/corpus.db"

SOURCE="${1:-$DEFAULT_SRC}"

# Validate source
if [[ ! -f "$SOURCE" ]]; then
    echo "Error: corpus.db not found at: $SOURCE"
    echo "Build it first with:  python3 corpus_build/build_corpus.py"
    exit 1
fi

DEST="$DEST_DIR/corpus.db"

echo "Copying corpus.db..."
echo "  from: $SOURCE"
echo "    to: $DEST"
cp "$SOURCE" "$DEST"

# Convert to DELETE journal mode so SQLite can open it read-only from the app bundle
# (WAL mode requires -wal/-shm files which can't exist in a read-only bundle)
echo "  Converting to non-WAL journal mode for bundle compatibility..."
python3 -c "
import sqlite3
c = sqlite3.connect('$DEST')
c.execute('PRAGMA wal_checkpoint(TRUNCATE);')
c.execute('PRAGMA journal_mode=DELETE;')
c.commit()
c.close()
"

# File size
SIZE=$(du -sh "$DEST" | awk '{print $1}')
echo "  size: $SIZE"

# Run xcodegen to add corpus.db to the Xcode project
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
    echo "Then re-run this script, or manually drag corpus.db into the Xcode project."
fi

echo ""
echo "Done. corpus.db ($SIZE) is installed at:"
echo "  $DEST"
