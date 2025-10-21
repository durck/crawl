#!/bin/bash

if [ $# -lt 1 ]; then
	echo "$0 words.db [words.db]"
	exit
fi

for db in $*
do echo "$db"
	echo "SELECT type,COUNT(1) FROM words GROUP BY type ORDER BY 2 DESC" | sqlite3 -separator $'\t' "$db" | column -t -s $'\t'
done
