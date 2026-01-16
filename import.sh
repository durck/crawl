#!/bin/bash

if [ $# -lt 1 ]; then
	echo "$0 words.csv [words.csv]"
	exit
fi

for csv in $*
do
	db=$(basename "$csv")
	db="${db%.*}".db
	if ! [ -e "$db" ]; then
		# FTS5 faster than FTS3, with better ranking
		echo "CREATE VIRTUAL TABLE words USING fts5(date, uri, ext, type, text, tokenize='porter unicode61');" | sqlite3 "$db"
	fi

	sqlite3 "$db" <<E
.separator ","
.import "$csv" words
E
done

# https://www.sqlite.org/fts5.html
