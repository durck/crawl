#!/bin/bash
#
# Search SQLite FTS5 databases
# Supports complex queries with BM25 ranking
#
# Usage: ./search.sh [options] 'QUERY' database.db [database2.db ...]
#

set -o pipefail

# Colors
GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
RED=$'\x1b[31m'
GREY=$'\x1b[90m'
RESET=$'\x1b[39m'

# Defaults
limit=10
offset=0
uri_filter=""
type_filter=""
ext_filter=""
server_filter=""
output_format="text"

# Usage
usage() {
    cat <<EOF
Usage: $0 [options] 'QUERY' database.db [database2.db ...]

Search SQLite FTS5 databases with full-text queries.

Options:
  -u PREFIX   Filter by URL/path prefix
  -t TYPE     Filter by file type (pdf, word, excel, etc.)
  -e EXT      Filter by extension (pdf, docx, xlsx, etc.)
  -s SERVER   Filter by server name
  -c COUNT    Number of results (default: 10)
  -o OFFSET   Results offset for pagination (default: 0)
  -j          Output as JSON
  -h          Show this help

FTS5 Query Syntax:
  word1 word2     Documents containing both words (AND)
  word1 OR word2  Documents containing either word
  "exact phrase"  Exact phrase match
  word*           Prefix search (words starting with...)
  NOT word        Exclude documents with word
  NEAR(w1 w2, N)  Words within N tokens of each other

Examples:
  $0 'password' crawl.db
  $0 -t pdf -c 20 'confidential' *.db
  $0 -u 'smb://server/share' 'budget 2024' data.db
  $0 '"api key" OR "secret token"' security_audit.db

EOF
    exit 1
}

# Parse options
while getopts "u:t:e:s:c:o:jh" opt; do
    case $opt in
        u) uri_filter="fullpath:\"$OPTARG*\"" ;;
        t) type_filter="filetype:$OPTARG" ;;
        e) ext_filter="ext:$OPTARG" ;;
        s) server_filter="server:$OPTARG" ;;
        c) limit=$OPTARG ;;
        o) offset=$OPTARG ;;
        j) output_format="json" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# Validate arguments
if [[ $# -lt 2 ]]; then
    usage
fi

query="$1"
shift
databases=("$@")

# Validate query (basic sanitization)
# Remove potentially dangerous characters but allow FTS5 operators
sanitized_query="${query//[;<>\\]/}"

# Build FTS5 query with filters
fts_query="$sanitized_query"
[[ -n "$uri_filter" ]] && fts_query="$fts_query $uri_filter"
[[ -n "$type_filter" ]] && fts_query="$fts_query $type_filter"
[[ -n "$ext_filter" ]] && fts_query="$fts_query $ext_filter"
[[ -n "$server_filter" ]] && fts_query="$fts_query $server_filter"

# Escape single quotes for SQL
sql_query="${fts_query//\'/\'\'}"

# JSON output start
if [[ "$output_format" == "json" ]]; then
    echo "["
    first_result=true
fi

# Search each database
total_results=0
for db in "${databases[@]}"; do
    if [[ ! -f "$db" ]]; then
        echo "${RED}[!] Database not found: $db${RESET}" >&2
        continue
    fi

    # Execute FTS5 search with BM25 ranking and snippet highlighting
    results=$(sqlite3 -separator $'\t' "$db" <<-SQL 2>/dev/null
        SELECT
            fullpath,
            filetype,
            server,
            share,
            snippet(words, 7, '${RED}', '${RESET}', '...', 64) as snippet
        FROM words
        WHERE words MATCH '$sql_query'
        ORDER BY bm25(words)
        LIMIT $limit
        OFFSET $offset;
SQL
    )

    if [[ -z "$results" ]]; then
        continue
    fi

    # Process results
    while IFS=$'\t' read -r fullpath filetype server share snippet; do
        ((total_results++))

        if [[ "$output_format" == "json" ]]; then
            # JSON output
            [[ "$first_result" != "true" ]] && echo ","
            first_result=false

            # Escape for JSON
            fullpath_json="${fullpath//\\/\\\\}"
            fullpath_json="${fullpath_json//\"/\\\"}"
            snippet_json="${snippet//\\/\\\\}"
            snippet_json="${snippet_json//\"/\\\"}"
            snippet_json="${snippet_json//$'\n'/\\n}"

            cat <<-JSON
    {
        "path": "$fullpath_json",
        "type": "$filetype",
        "server": "$server",
        "share": "$share",
        "snippet": "$snippet_json",
        "database": "$db"
    }
JSON
        else
            # Text output
            location=""
            [[ -n "$server" ]] && location=" ${GREY}[$server/$share]${RESET}"
            echo "${GREEN}$fullpath${RESET} ${YELLOW}[$filetype]${RESET}$location"
            echo "$snippet"
            echo ""
        fi
    done <<< "$results"
done

# JSON output end
if [[ "$output_format" == "json" ]]; then
    echo ""
    echo "]"
fi

# Summary
if [[ "$output_format" != "json" ]]; then
    if [[ $total_results -eq 0 ]]; then
        echo "${YELLOW}No results found for: $query${RESET}"
    else
        echo "${GREY}Found $total_results results${RESET}"
    fi
fi
