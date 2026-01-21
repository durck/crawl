#!/bin/bash
#
# IMAP Email Crawler - Download emails from IMAP servers
# Downloads all folders and messages for offline crawling
#
# Usage: ./imap.sh [options] imap://server.com
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common functions if available
if [[ -f "$SCRIPT_DIR/lib/common.sh" ]]; then
    source "$SCRIPT_DIR/lib/common.sh"
else
    # Minimal fallback
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ============================================
# Configuration
# ============================================
TIMEOUT="${IMAP_TIMEOUT:-30}"
MAX_MESSAGES="${IMAP_MAX_MESSAGES:-10000}"
INSECURE="${IMAP_INSECURE:-true}"

# ============================================
# Load credentials
# ============================================
load_imap_credentials() {
    # Try environment variables first
    if [[ -n "${IMAP_USER:-}" && -n "${IMAP_PASS:-}" ]]; then
        CREDS="${IMAP_USER}:${IMAP_PASS}"
        return 0
    fi

    # Try credentials file
    local cred_files=(
        "$HOME/.crawl-credentials.conf"
        "/etc/crawl/credentials.conf"
        "$SCRIPT_DIR/config/credentials.conf"
    )

    for cred_file in "${cred_files[@]}"; do
        if [[ -f "$cred_file" ]]; then
            source "$cred_file" 2>/dev/null
            if [[ -n "${IMAP_USER:-}" && -n "${IMAP_PASS:-}" ]]; then
                CREDS="${IMAP_USER}:${IMAP_PASS}"
                return 0
            fi
        fi
    done

    return 1
}

# ============================================
# Usage
# ============================================
usage() {
    cat <<EOF
Usage: $0 [options] imap://server.com

Download emails from IMAP servers for offline crawling.

Options:
  -u, --user USER:PASS  IMAP credentials (user:password)
  -t, --timeout N       Connection timeout (default: $TIMEOUT)
  -m, --max N           Max messages per folder (default: $MAX_MESSAGES)
  -k, --insecure        Allow insecure SSL (default: $INSECURE)
  -o, --output DIR      Output directory (default: email address)
  -h, --help            Show this help

Environment variables:
  IMAP_USER             IMAP username
  IMAP_PASS             IMAP password
  IMAP_TIMEOUT          Connection timeout
  IMAP_MAX_MESSAGES     Max messages per folder
  IMAP_INSECURE         Allow insecure SSL (true/false)

Examples:
  $0 imaps://imap.gmail.com
  $0 -u user@gmail.com:password imaps://imap.gmail.com
  $0 --max 100 imap://mail.example.com

Output:
  Creates directory structure: email/folder/xxNN files
  Each xxNN file contains one email message in EML format.

EOF
    exit 1
}

# ============================================
# IMAP Functions
# ============================================

# Build curl options
get_curl_opts() {
    local opts=(-s --max-time "$TIMEOUT")

    if [[ "$INSECURE" == "true" ]]; then
        opts+=(--insecure)
    fi

    if [[ -n "${CREDS:-}" ]]; then
        opts+=(--user "$CREDS")
    fi

    echo "${opts[@]}"
}

# Get list of folders
get_folders() {
    local curl_opts
    read -ra curl_opts <<< "$(get_curl_opts)"

    curl "${curl_opts[@]}" "$SERVER" 2>/dev/null | \
        sed -rn 's/.* ([^\s]+)/\1/p' | \
        tr -d '\r'
}

# Get message count for a folder
get_messages_count() {
    local folder="$1"
    local curl_opts
    read -ra curl_opts <<< "$(get_curl_opts)"

    local count
    count=$(curl "${curl_opts[@]}" "$SERVER" -X "EXAMINE $folder" 2>/dev/null | \
        grep EXISTS | \
        sed -rn 's/\* ([0-9]+) .*/\1/p' | \
        head -n 1)

    # Return 0 if empty or not a number
    if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$count"
    fi
}

# Download messages from folder
get_messages() {
    local folder="$1"
    local messages_count="$2"
    local curl_opts
    read -ra curl_opts <<< "$(get_curl_opts)"

    # Skip if no messages
    if [[ "$messages_count" -eq 0 ]]; then
        log_info "  No messages in folder"
        return 0
    fi

    # Limit message count
    if [[ "$messages_count" -gt "$MAX_MESSAGES" ]]; then
        log_warn "  Limiting to $MAX_MESSAGES messages (folder has $messages_count)"
        messages_count="$MAX_MESSAGES"
    fi

    # Download all messages
    local tmp_file="messages.eml.tmp"
    if ! curl "${curl_opts[@]}" "$SERVER/$folder;UID=[1-$messages_count]" > "$tmp_file" 2>/dev/null; then
        log_error "  Failed to download messages"
        rm -f "$tmp_file"
        return 1
    fi

    # Check if we got any data
    if [[ ! -s "$tmp_file" ]]; then
        log_warn "  No message data received"
        rm -f "$tmp_file"
        return 0
    fi

    # Split into individual messages
    if csplit -s "$tmp_file" '/^Return-Path:/' '{*}' 2>/dev/null; then
        # Remove temp file and empty first split
        rm -f "$tmp_file" xx00 2>/dev/null

        # Count downloaded messages
        local downloaded
        downloaded=$(ls xx* 2>/dev/null | wc -l)
        log_info "  Downloaded $downloaded messages"
    else
        # csplit failed, try alternative approach
        log_warn "  csplit failed, saving as single file"
        mv "$tmp_file" "messages.eml"
    fi

    return 0
}

# ============================================
# Parse arguments
# ============================================
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            CREDS="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -m|--max)
            MAX_MESSAGES="$2"
            shift 2
            ;;
        -k|--insecure)
            INSECURE="true"
            shift
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            SERVER="$1"
            shift
            ;;
    esac
done

# Validate server URL
if [[ -z "${SERVER:-}" ]]; then
    log_error "Server URL required"
    usage
fi

# Validate URL format
if [[ ! "$SERVER" =~ ^imaps?:// ]]; then
    log_error "Invalid server URL. Must start with imap:// or imaps://"
    exit 1
fi

# ============================================
# Load credentials if not provided
# ============================================
if [[ -z "${CREDS:-}" ]]; then
    if ! load_imap_credentials; then
        log_info "No credentials found. Enter user:pass:"
        read -r CREDS
        if [[ -z "$CREDS" ]]; then
            log_error "Credentials required"
            exit 1
        fi
    fi
fi

# Extract email from credentials for output directory
EMAIL="${CREDS%%:*}"

# Set output directory
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$EMAIL"
fi

# Sanitize output directory name
OUTPUT_DIR=$(echo "$OUTPUT_DIR" | tr -cd 'a-zA-Z0-9._@-')

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="imap_download"
fi

# ============================================
# Main
# ============================================
log_info "Starting IMAP crawler"
log_info "Server: $SERVER"
log_info "User: $EMAIL"
log_info "Output: $OUTPUT_DIR"

# Create output directory
if ! mkdir -p "$OUTPUT_DIR"; then
    log_error "Failed to create output directory: $OUTPUT_DIR"
    exit 1
fi

cd "$OUTPUT_DIR" || exit 1

# Get folder list
log_info "Fetching folder list..."
folders=$(get_folders)

if [[ -z "$folders" ]]; then
    log_error "No folders found or connection failed"
    exit 1
fi

folder_count=$(echo "$folders" | wc -l)
log_info "Found $folder_count folders"

# Process each folder
current=0
for folder in $folders; do
    ((current++))

    # Skip empty folder names
    [[ -z "$folder" ]] && continue

    # Sanitize folder name for filesystem
    safe_folder=$(echo "$folder" | tr -cd 'a-zA-Z0-9._-' | head -c 200)
    [[ -z "$safe_folder" ]] && safe_folder="folder_$current"

    log_info "[$current/$folder_count] Processing: $folder"

    # Create folder directory
    if ! mkdir -p "$safe_folder"; then
        log_warn "  Failed to create directory: $safe_folder"
        continue
    fi

    cd "$safe_folder" || continue

    # Get message count
    max=$(get_messages_count "$folder")
    log_info "  Messages: $max"

    # Download messages
    if [[ "$max" -gt 0 ]]; then
        get_messages "$folder" "$max"
    fi

    cd ..
done

log_info "IMAP crawl complete"
log_info "Output directory: $(pwd)"
