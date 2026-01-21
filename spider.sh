#!/bin/bash
#
# Spider - Web/FTP recursive downloader
# Wrapper for wget with sensible defaults for crawling
#
# Usage: ./spider.sh [options] URL
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================
# Configuration
# ============================================
USER_AGENT="${SPIDER_USER_AGENT:-Mozilla/5.0 (compatible; Crawlbot/2.0)}"
IGNORE_EXT="${SPIDER_IGNORE_EXT:-woff,woff2,ttf,eot,otf}"
MAX_SIZE="${SPIDER_MAX_SIZE:-50m}"
WAIT="${SPIDER_WAIT:-1}"
LEVEL="${SPIDER_LEVEL:-5}"
TIMEOUT="${SPIDER_TIMEOUT:-30}"

# Use custom wget if available (with SSL fixes)
if [[ -x "$SCRIPT_DIR/bin/wget" ]]; then
    WGET="$SCRIPT_DIR/bin/wget"
else
    WGET="wget"
fi

# ============================================
# Usage
# ============================================
usage() {
    cat <<EOF
Usage: $0 [options] URL

Download websites recursively for offline crawling.

Options:
  -l, --level N        Recursion depth (default: $LEVEL)
  -w, --wait N         Wait N seconds between requests (default: $WAIT)
  -s, --max-size SIZE  Skip files larger than SIZE (default: $MAX_SIZE)
  -d, --domains LIST   Limit to these domains (comma-separated)
  -A, --accept EXT     Accept only these extensions
  -R, --reject EXT     Reject these extensions
  -X, --exclude DIR    Exclude directories
  -t, --timeout N      Connection timeout (default: $TIMEOUT)
  --spider             Don't download, just check links
  --mirror             Mirror mode (infinite depth, timestamping)
  -h, --help           Show this help

Environment variables:
  SPIDER_USER_AGENT    User agent string
  SPIDER_IGNORE_EXT    Extensions to ignore (default: $IGNORE_EXT)
  SPIDER_MAX_SIZE      Max file size (default: $MAX_SIZE)
  SPIDER_WAIT          Wait between requests (default: $WAIT)
  SPIDER_LEVEL         Recursion depth (default: $LEVEL)

Examples:
  $0 http://example.com/
  $0 --level 3 --wait 2 http://example.com/docs/
  $0 --mirror --domains example.com http://example.com/
  $0 ftp://files.example.com/pub/

Output:
  Downloaded files are saved to current directory
  maintaining the original directory structure.

EOF
    exit 1
}

# ============================================
# Parse arguments
# ============================================
WGET_OPTS=()
SPIDER_MODE=false
MIRROR_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--level)
            LEVEL="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT="$2"
            shift 2
            ;;
        -s|--max-size)
            MAX_SIZE="$2"
            shift 2
            ;;
        -d|--domains)
            WGET_OPTS+=(--domains "$2")
            shift 2
            ;;
        -A|--accept)
            WGET_OPTS+=(-A "$2")
            shift 2
            ;;
        -R|--reject)
            WGET_OPTS+=(-R "$2")
            shift 2
            ;;
        -X|--exclude)
            WGET_OPTS+=(-X "$2")
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --spider)
            SPIDER_MODE=true
            shift
            ;;
        --mirror)
            MIRROR_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            URL="$1"
            shift
            ;;
    esac
done

# Validate URL
if [[ -z "${URL:-}" ]]; then
    echo "Error: URL required" >&2
    usage
fi

# ============================================
# Build wget command
# ============================================
WGET_CMD=(
    "$WGET"
    --no-check-certificate
    -e robots=off
    -U "$USER_AGENT"
    --no-verbose
    --timeout="$TIMEOUT"
    --tries=3
    --waitretry=1
    -R "$IGNORE_EXT"
)

if [[ "$SPIDER_MODE" == "true" ]]; then
    # Spider mode - just check links
    WGET_CMD+=(
        --spider
        --recursive
        --level="$LEVEL"
        -O /dev/null
    )
elif [[ "$MIRROR_MODE" == "true" ]]; then
    # Mirror mode - full site copy
    WGET_CMD+=(
        --mirror
        --no-parent
        --page-requisites
        --convert-links
        --adjust-extension
        --wait="$WAIT"
    )
else
    # Normal recursive download
    WGET_CMD+=(
        --recursive
        --level="$LEVEL"
        --no-clobber
        --wait="$WAIT"
        --quota="$MAX_SIZE"
    )
fi

# Add extra options
WGET_CMD+=("${WGET_OPTS[@]}")

# Add URL
WGET_CMD+=("$URL")

# ============================================
# Execute
# ============================================
echo "[*] Starting spider: $URL"
echo "[*] Depth: $LEVEL, Wait: ${WAIT}s, Max size: $MAX_SIZE"

"${WGET_CMD[@]}" 2>&1 | while read -r line; do
    # Extract and display URLs
    if [[ "$line" == *"URL:"* ]]; then
        echo "$line" | sed -rn 's|.*URL:[ ]*([^ ]+).*|\1|p'
    fi
done

echo "[*] Spider complete"
