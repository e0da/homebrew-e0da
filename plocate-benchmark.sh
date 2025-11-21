#!/bin/bash
set -ex

PLOCATE_BIN="/tmp/plocate-1.1.23-test/build-test/plocate"
UPDATEDB_BIN="/tmp/plocate-1.1.23-test/build-test/updatedb"
PLOCATE_DB="/var/db/plocate/plocate.db"
MLOCATE_DB="/var/db/locate.database"
TEST_DIR="$HOME"

# Remove existing databases for clean baseline
time sudo rm -f "$PLOCATE_DB" "$MLOCATE_DB"

echo ""
echo "Building native macOS locate database..."
time sudo /usr/libexec/locate.updatedb
echo ""

echo "Building plocate database with libuv..."
time sudo "$UPDATEDB_BIN" -U "$TEST_DIR" -o "$PLOCATE_DB" 2>&1 | grep -v "^Unknown group" || true
echo ""

# Verify plocate database exists
if [ ! -f "$PLOCATE_DB" ]; then
    echo "Error: plocate database not created at $PLOCATE_DB"
    ls -la /var/db/ | grep plocate
    exit 1
fi

# Pick a search term that should exist in home directory
SEARCH_TERM=".md"

echo "Searching for '$SEARCH_TERM' with native locate:"
time locate "$SEARCH_TERM" | head -5
echo ""

echo "Searching for '$SEARCH_TERM' with plocate:"
time "$PLOCATE_BIN" -d "$PLOCATE_DB" "$SEARCH_TERM" | head -5
echo ""

echo "Database sizes:"
time ls -lh /var/db/locate.database /var/db/plocate.db 2>/dev/null || time ls -lh /var/db/locate.database
