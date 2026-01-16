#!/bin/bash

GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
RED=$'\x1b[31m'
RESET=$'\x1b[39m'

limit=10
offset=0
uri_filter=''
type_filter=''
ext_filter=''

while getopts "u:t:e:c:o:" opt
do
	case $opt in
		u) uri_filter="uri:\"$OPTARG*\"";;
		t) type_filter="type:$OPTARG";;
		e) ext_filter="ext:$OPTARG";;
		c) limit=$OPTARG;;
		o) offset=$OPTARG;;
	esac
done

if [[ $[$#-$OPTIND] -lt 1 ]]; then
	echo "$0 [opts] 'QUERY' words.db [words.db]"
	echo "opts:"
	echo "  -u url     - filter by URL prefix"
	echo "  -t type    - filter by file type"
	echo "  -e ext     - filter by extension"
	echo "  -c count   - results count (default: 10)"
	echo "  -o offset  - results offset (default: 0)"
	echo ""
	echo "FTS5 query syntax:"
	echo "  word1 word2     - documents containing both words"
	echo "  word1 OR word2  - documents containing either word"
	echo "  \"exact phrase\" - exact phrase match"
	echo "  word*           - prefix search"
	echo "  NOT word        - exclude word"
	exit
fi

query="${@:$OPTIND:1}"
dbs="${@:$[OPTIND+1]}"

# Build FTS5 query with filters
fts_query="$query"
[ -n "$uri_filter" ] && fts_query="$fts_query $uri_filter"
[ -n "$type_filter" ] && fts_query="$fts_query $type_filter"
[ -n "$ext_filter" ] && fts_query="$fts_query $ext_filter"

for db in $dbs
do
	# FTS5 with snippet() for highlighted results and bm25() for ranking
	sqlite3 -separator $'\t' "$db" "SELECT uri, type, snippet(words, 4, '$RED', '$RESET', '...', 50) FROM words WHERE words MATCH '${fts_query//\'/\'\'}' ORDER BY bm25(words) LIMIT $limit OFFSET $offset;" 2>/dev/null | while IFS=$'\t' read uri type snippet
	do
		echo "${GREEN}$uri ${YELLOW}[$type]${RESET}"
		echo "$snippet"
		echo ""
	done
done
