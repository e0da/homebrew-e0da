#!/bin/bash
set -ex

# Configuration with environment variable overrides and defaults
SCAN_DIR="${SCAN_DIR:-/tmp/plocate-benchmark-data}"
PLOCATE_BIN="${PLOCATE_BIN:-/tmp/plocate-1.1.23-test/build-test/plocate}"
UPDATEDB_BIN="${UPDATEDB_BIN:-/tmp/plocate-1.1.23-test/build-test/updatedb}"
PLOCATE_DB="${PLOCATE_DB:-/tmp/plocate-bench.db}"
MLOCATE_DB="${MLOCATE_DB:-/tmp/mlocate-bench.db}"
SEARCH_TERM="${SEARCH_TERM:-.txt}"

echo "=== Configuration ==="
echo "Scan directory: $SCAN_DIR"
echo "Search term: $SEARCH_TERM"
echo ""

# Create test data if needed
if [ ! -d "$SCAN_DIR" ]; then
    echo "Creating test directory structure at $SCAN_DIR"
    mkdir -p "$SCAN_DIR"
    # Create a variety of files
    for i in {1..100}; do
        mkdir -p "$SCAN_DIR/dir_$i"
        touch "$SCAN_DIR/dir_$i/file_$i.txt"
        touch "$SCAN_DIR/dir_$i/doc_$i.md"
        touch "$SCAN_DIR/dir_$i/data_$i.log"
    done
fi

echo ""
echo "=== Native macOS locate ==="

time sudo rm -f "$MLOCATE_DB"

echo ""
echo "Indexing with mlocate..."
time sudo /usr/libexec/locate.updatedb 2>&1 | tail -5

echo ""
echo "Searching for '$SEARCH_TERM' with mlocate..."
time locate "$SEARCH_TERM" 2>&1 | head -5

echo ""
echo "=== plocate with libuv ==="

time sudo rm -f "$PLOCATE_DB"

echo ""
echo "Indexing with plocate..."
time sudo "$UPDATEDB_BIN" -U "$SCAN_DIR" -o "$PLOCATE_DB" -l no 2>&1 | tail -5

echo ""
echo "Searching for '$SEARCH_TERM' with plocate..."
time sudo "$PLOCATE_BIN" -d "$PLOCATE_DB" "$SEARCH_TERM" 2>&1 | head -5

echo ""
echo "=== Database Comparison ==="
time ls -lh "$MLOCATE_DB" "$PLOCATE_DB"
