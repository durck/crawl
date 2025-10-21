#!/bin/bash

GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
RESET=$'\x1b[39m'

if [ $# -lt 1 ]; then
	echo "$0 'path' words.db [words.db]"
	exit
fi

path="$1"
for db in ${@:2}
do
	echo "SELECT uri,type,text FROM words WHERE uri LIKE '%$path%'" | sqlite3 -separator '%' "$db" | while IFS='%' read uri type text
	do
		echo "${GREEN}$uri ${YELLOW}[$type]${RESET}"
		echo "$text"
		echo ""
	done
done
