#!/bin/bash
#
# Import CSV files to SQLite FTS5 database
# Creates full-text search index with porter stemming
#
# Usage: ./import.sh file1.csv [file2.csv ...]
#

set -o pipefail

# Colors
RED=$'\x1b[31m'
GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
RESET=$'\x1b[39m'

# Usage
if [[ $# -lt 1 ]]; then
    cat <<EOF
Usage: $0 file1.csv [file2.csv ...]

Import CSV files into SQLite FTS5 databases for full-text search.

Examples:
  $0 smb_server_share.csv
  $0 *.csv
  $0 crawl1.csv crawl2.csv crawl3.csv

Output:
  Creates .db file for each .csv file with FTS5 virtual table

FTS5 Features:
  - Porter stemming for better search
  - Unicode61 tokenizer for international text
  - BM25 ranking for relevance scoring

EOF
    exit 1
fi

# Process each CSV file
for csv in "$@"; do
    # Validate file exists
    if [[ ! -f "$csv" ]]; then
        echo "${RED}[!] File not found: $csv${RESET}"
        continue
    fi

    # Generate database name
    db="$(basename "$csv")"
    db="${db%.*}.db"

    echo "${GREEN}[*] Importing: $csv -> $db${RESET}"

    # Create FTS5 table if database doesn't exist
    if [[ ! -e "$db" ]]; then
        echo "${YELLOW}[*] Creating new FTS5 database${RESET}"
        sqlite3 "$db" <<-'SQL'
            -- FTS5 virtual table with porter stemmer and unicode support
            CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(
                timestamp,
                fullpath,
                relpath,
                server,
                share,
                ext,
                filetype,
                content,
                tokenize='porter unicode61'
            );

            -- Metadata table for tracking imports
            CREATE TABLE IF NOT EXISTS import_log (
                id INTEGER PRIMARY KEY,
                source_file TEXT,
                imported_at TEXT DEFAULT (datetime('now')),
                row_count INTEGER
            );
SQL
    fi

    # Count rows before import
    rows_before=$(sqlite3 "$db" "SELECT COUNT(*) FROM words" 2>/dev/null || echo 0)

    # Import CSV data
    # Using proper CSV mode with comma separator
    sqlite3 "$db" <<-SQL
        .mode csv
        .separator ","
        .import "$csv" words
SQL

    # Count rows after import
    rows_after=$(sqlite3 "$db" "SELECT COUNT(*) FROM words" 2>/dev/null || echo 0)
    rows_imported=$((rows_after - rows_before))

    # Log the import
    sqlite3 "$db" "INSERT INTO import_log (source_file, row_count) VALUES ('$csv', $rows_imported)"

    echo "${GREEN}[+] Imported $rows_imported rows (total: $rows_after)${RESET}"
done

echo ""
echo "${GREEN}[+] Import complete${RESET}"

# Show summary
echo ""
echo "Database statistics:"
for csv in "$@"; do
    db="$(basename "$csv")"
    db="${db%.*}.db"
    if [[ -f "$db" ]]; then
        count=$(sqlite3 "$db" "SELECT COUNT(*) FROM words" 2>/dev/null || echo 0)
        size=$(du -h "$db" 2>/dev/null | cut -f1)
        echo "  $db: $count documents, $size"
    fi
done

# FTS5 documentation reference
# https://www.sqlite.org/fts5.html
