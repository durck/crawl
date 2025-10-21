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
		echo "CREATE VIRTUAL TABLE words USING fts3(date DATETIME, uri TEXT, ext TEXT, type TEXT, text TEXT);" | sqlite3 "$db"
	fi

	sqlite3 "$db" <<E
.separator ","
.import "$csv" words
E
done

# https://www.sqlite.org/fts3.html
