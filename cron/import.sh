#!/bin/bash

INDEX="company"
DB="localhost:9200"
PARALLEL_JOBS=4

# Collect all CSV files
csvs=$(ls www/*.csv ftp/*.csv smb-all/*.csv smb-new/*.csv nfs/*.csv rsync/*.csv 2>/dev/null)

if [ -z "$csvs" ]; then
    echo "[*] No CSV files to import"
    exit 0
fi

echo "[*] Found $(echo "$csvs" | wc -w) CSV files to import"

# Import in parallel
echo "$csvs" | xargs -P "$PARALLEL_JOBS" -I {} sh -c '
    csv="{}"
    echo "[+] Importing: $csv"
    /opt/crawl/opensearch.py "'"$DB"'" -i "'"$INDEX"'" -import "$csv" && rm "$csv"
'

echo "[+] Import complete"
