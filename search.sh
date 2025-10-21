#!/bin/bash

GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
RESET=$'\x1b[39m'

match=30
limit=10
offset=0
uri='%'
type='%'
ext='%'

while getopts "u:t:e:m:c:o:" opt
do
	case $opt in
		u) uri=$OPTARG;;
		t) type=$OPTARG;;
		e) ext=$OPTARG;;
		m) match=$OPTARG;;
		c) limit=$OPTARG;;
		o) offset=$OPTARG;;
	esac
done

if [[ $[$#-$OPTIND] -lt 1 ]] && [[ "$uri" = '%' && "$type" = '%' && "$ext" = '%' ]]; then
	echo "$0 [opts] 'QUERY' words.db [words.db]"
	echo "opts:"
	echo "  -u url"
	echo "  -t type"
	echo "  -e ext"
	echo "  -m match"
	echo "  -c count"
	echo "  -o offset"
	exit
fi

query="${@:$OPTIND:1}"
dbs="${@:$[OPTIND+1]}"
for db in $dbs
do
	echo "SELECT uri,type,text FROM words WHERE uri LIKE '$uri' and type LIKE '$type' and ext LIKE '$ext' and text LIKE '%$query%' limit $limit offset $offset;" | sqlite3 -separator '%' "$db" | while IFS='%' read uri type text
	do
		echo "${GREEN}$uri ${YELLOW}[$type]${RESET}"
		echo "$text" | grep -i -o -P ".{0,$match}$query..{0,$match}" | grep -i --color=auto "$query"
		echo ""
	done
done
