#!/bin/bash
# Common functions for Crawl toolkit
# Source this file: source "$(dirname "$0")/lib/common.sh"

set -o pipefail

# ============================================
# Colors
# ============================================
readonly RED=$'\x1b[31m'
readonly GREEN=$'\x1b[32m'
readonly YELLOW=$'\x1b[33m'
readonly BLUE=$'\x1b[34m'
readonly GREY=$'\x1b[90m'
readonly RESET=$'\x1b[39m'
readonly BOLD=$'\x1b[1m'
readonly NOBOLD=$'\x1b[22m'

# ============================================
# Globals
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_LOADED=0
CLEANUP_ITEMS=()

# ============================================
# Configuration Loading
# ============================================
load_config() {
    [[ $CONFIG_LOADED -eq 1 ]] && return 0

    # Default values
    MAX_RECURSION_DEPTH=5
    DEFAULT_THREADS=4
    COMMAND_TIMEOUT=60
    MAX_FILESIZE="100M"
    TEMP_DIR=""
    OCR_LANGS="eng rus"
    OCR_MIN_TEXT=100
    OCR_MAX_IMAGES=10
    OCR_DISABLED=0
    AUDIO_LANGS="en-us ru"
    AUDIO_DISABLED=0
    IMAGES=""
    IMAGE_THUMBNAIL_SIZE="640x480"
    USE_SQLITE_SESSION=1
    SESSION_DB_SUFFIX=".session.db"
    LOG_LEVEL="INFO"
    LOG_FILE=""
    CSV_BUFFER_SIZE=65536
    OPENSEARCH_BATCH_SIZE=500
    EXCLUDE_DIRS=""
    EXCLUDE_PATTERNS=""
    EXCLUDE_MIMES=""
    DEDUPE_ENABLED=0
    DEDUPE_HASH="md5"
    MOUNT_TIMEOUT=10
    CRAWL_TIMEOUT=300
    SMB_VERSIONS="3.0,2.1,2.0,1.0"
    OPENSEARCH_SHARDS=1
    OPENSEARCH_REPLICAS=0

    # Load config files (later files override earlier)
    local config_files=(
        "$SCRIPT_DIR/config/crawl.conf"
        "/etc/crawl/crawl.conf"
        "$HOME/.crawl.conf"
        "${CRAWL_CONFIG:-}"
    )

    for config in "${config_files[@]}"; do
        if [[ -n "$config" && -f "$config" ]]; then
            # shellcheck source=/dev/null
            source "$config" 2>/dev/null || log_warn "Failed to load config: $config"
        fi
    done

    CONFIG_LOADED=1
}

load_credentials() {
    # Credentials files (should have restricted permissions)
    local cred_files=(
        "$SCRIPT_DIR/config/credentials.conf"
        "/etc/crawl/credentials.conf"
        "$HOME/.crawl-credentials.conf"
        "${CRAWL_CREDENTIALS:-}"
    )

    for cred in "${cred_files[@]}"; do
        if [[ -n "$cred" && -f "$cred" ]]; then
            # Check permissions (warn if world-readable)
            local perms
            perms=$(stat -c %a "$cred" 2>/dev/null || stat -f %OLp "$cred" 2>/dev/null)
            if [[ "${perms: -1}" != "0" ]]; then
                log_warn "Credentials file $cred is world-readable! Run: chmod 600 $cred"
            fi
            # shellcheck source=/dev/null
            source "$cred" 2>/dev/null
        fi
    done

    # Override from environment variables
    OPENSEARCH_USER="${OPENSEARCH_USER:-admin}"
    OPENSEARCH_PASS="${OPENSEARCH_PASS:-}"
    SMB_DOMAIN="${SMB_DOMAIN:-}"
    SMB_USER="${SMB_USER:-}"
    SMB_PASS="${SMB_PASS:-}"
}

# ============================================
# Logging
# ============================================
_log_level_num() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

_should_log() {
    local level="$1"
    local current_level="${LOG_LEVEL:-INFO}"
    [[ $(_log_level_num "$level") -ge $(_log_level_num "$current_level") ]]
}

_log() {
    local level="$1"
    local color="$2"
    shift 2
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    _should_log "$level" || return 0

    local line="[$timestamp] [$level] $message"
    echo -e "${color}${line}${RESET}" >&2

    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

log_debug() { _log "DEBUG" "$GREY" "$@"; }
log_info()  { _log "INFO"  "$GREEN" "$@"; }
log_warn()  { _log "WARN"  "$YELLOW" "$@"; }
log_error() { _log "ERROR" "$RED" "$@"; }

# ============================================
# Cleanup Management
# ============================================
cleanup_register() {
    CLEANUP_ITEMS+=("$1")
}

cleanup_run() {
    local item
    for item in "${CLEANUP_ITEMS[@]}"; do
        if [[ -d "$item" ]]; then
            rm -rf "$item" 2>/dev/null
        elif [[ -f "$item" ]]; then
            rm -f "$item" 2>/dev/null
        elif [[ "$item" == umount:* ]]; then
            local mnt="${item#umount:}"
            sudo umount "$mnt" 2>/dev/null
        fi
    done
    CLEANUP_ITEMS=()
}

trap_setup() {
    trap 'cleanup_run; exit 130' INT
    trap 'cleanup_run; exit 143' TERM
    trap 'cleanup_run' EXIT
}

# ============================================
# Path Utilities
# ============================================
sanitize_path() {
    local path="$1"
    # Remove path traversal attempts
    path="${path//..\/}"
    path="${path//\/..\//}"
    path="${path//..\\}"
    path="${path//\\..\\//}"
    # Remove null bytes
    path="${path//$'\0'/}"
    echo "$path"
}

validate_path() {
    local path="$1"
    local allow_absolute="${2:-1}"  # Allow absolute paths by default

    # Check for path traversal
    if [[ "$path" == *".."* ]]; then
        log_error "Path traversal not allowed: $path"
        return 1
    fi

    # Check for null bytes
    if [[ "$path" == *$'\0'* ]]; then
        log_error "Invalid path (null byte): $path"
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        log_error "Path does not exist: $path"
        return 1
    fi

    return 0
}

# Legacy alias for backwards compatibility
validate_relative_path() {
    validate_path "$1" 0
}

make_temp_dir() {
    local prefix="${1:-crawl}"
    local base="${TEMP_DIR:-${TMPDIR:-/tmp}}"
    mktemp -d "$base/${prefix}.XXXXXX"
}

# ============================================
# CSV Utilities
# ============================================
escape_csv() {
    # Proper CSV escaping: double quotes around field, escape internal quotes
    local input
    input=$(cat)
    # Remove null bytes, carriage returns
    input="${input//$'\0'/}"
    input="${input//$'\r'/}"
    # Escape double quotes by doubling them
    input="${input//\"/\"\"}"
    # Remove/replace problematic characters
    input="${input//$'\n'/ }"
    printf '"%s"' "$input"
}

escape_csv_fast() {
    # Faster version for piping, removes problematic chars
    tr -d '\0\r\n",' | tr -s ' '
}

# ============================================
# Session Management (SQLite-based)
# ============================================
session_init() {
    local session_db="$1"

    if [[ "${USE_SQLITE_SESSION:-1}" == "1" ]]; then
        sqlite3 "$session_db" <<-'SQL'
            CREATE TABLE IF NOT EXISTS processed (
                path TEXT PRIMARY KEY,
                timestamp INTEGER DEFAULT (strftime('%s', 'now')),
                status TEXT DEFAULT 'done'
            );
            CREATE INDEX IF NOT EXISTS idx_path ON processed(path);
SQL
    else
        touch "$session_db"
    fi
}

session_is_done() {
    local session_db="$1"
    local path="$2"

    if [[ "${USE_SQLITE_SESSION:-1}" == "1" ]]; then
        local count
        count=$(sqlite3 "$session_db" "SELECT COUNT(*) FROM processed WHERE path = '${path//\'/\'\'}'" 2>/dev/null)
        [[ "$count" -gt 0 ]]
    else
        grep -Fxq "[$path]" "$session_db" 2>/dev/null
    fi
}

session_mark_done() {
    local session_db="$1"
    local path="$2"

    if [[ "${USE_SQLITE_SESSION:-1}" == "1" ]]; then
        sqlite3 "$session_db" "INSERT OR IGNORE INTO processed(path) VALUES('${path//\'/\'\'}')" 2>/dev/null
    else
        echo "[$path]" >> "$session_db"
    fi
}

session_count() {
    local session_db="$1"

    if [[ "${USE_SQLITE_SESSION:-1}" == "1" ]]; then
        sqlite3 "$session_db" "SELECT COUNT(*) FROM processed" 2>/dev/null || echo 0
    else
        wc -l < "$session_db" 2>/dev/null || echo 0
    fi
}

# ============================================
# Deduplication
# ============================================
compute_hash() {
    local file="$1"
    local algo="${DEDUPE_HASH:-md5}"

    case "$algo" in
        md5)    md5sum "$file" 2>/dev/null | cut -d' ' -f1 ;;
        sha1)   sha1sum "$file" 2>/dev/null | cut -d' ' -f1 ;;
        sha256) sha256sum "$file" 2>/dev/null | cut -d' ' -f1 ;;
        *)      md5sum "$file" 2>/dev/null | cut -d' ' -f1 ;;
    esac
}

dedupe_init() {
    local dedupe_db="$1"
    sqlite3 "$dedupe_db" <<-'SQL'
        CREATE TABLE IF NOT EXISTS hashes (
            hash TEXT PRIMARY KEY,
            first_path TEXT,
            timestamp INTEGER DEFAULT (strftime('%s', 'now'))
        );
SQL
}

dedupe_check() {
    local dedupe_db="$1"
    local hash="$2"
    local count
    count=$(sqlite3 "$dedupe_db" "SELECT COUNT(*) FROM hashes WHERE hash = '$hash'" 2>/dev/null)
    [[ "$count" -gt 0 ]]
}

dedupe_add() {
    local dedupe_db="$1"
    local hash="$2"
    local path="$3"
    sqlite3 "$dedupe_db" "INSERT OR IGNORE INTO hashes(hash, first_path) VALUES('$hash', '${path//\'/\'\'}')" 2>/dev/null
}

# ============================================
# URL/Path Parsing
# ============================================
parse_crawl_path() {
    local target="$1"

    # Parse: proto/server/share/path...
    IFS='/' read -ra parts <<< "$target"

    CRAWL_PROTO="${parts[0]:-}"
    CRAWL_SERVER="${parts[1]:-}"
    CRAWL_SHARE="${parts[2]:-}"
    CRAWL_SUBPATH="${parts[*]:3}"
    CRAWL_SUBPATH="${CRAWL_SUBPATH// //}"

    # Generate browser-compatible URL
    case "$CRAWL_PROTO" in
        smb|nfs)
            CRAWL_BASE_URL="file://${CRAWL_SERVER}/${CRAWL_SHARE}"
            ;;
        ftp|http|https)
            CRAWL_BASE_URL="${CRAWL_PROTO}://${CRAWL_SERVER}/${CRAWL_SHARE}"
            ;;
        *)
            CRAWL_BASE_URL=""
            ;;
    esac
}

# ============================================
# Command Execution with Timeout
# ============================================
run_with_timeout() {
    local timeout_sec="${1:-$COMMAND_TIMEOUT}"
    shift
    timeout "$timeout_sec" "$@" 2>/dev/null
}

# Check if command exists
require_cmd() {
    local cmd="$1"
    local package="${2:-$1}"

    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd (install: $package)"
        return 1
    fi
    return 0
}

# ============================================
# Input Validation
# ============================================
validate_query() {
    local query="$1"
    # Remove potentially dangerous characters for SQL/NoSQL
    query="${query//[;<>\"\'\\$\`]/}"
    # Limit length
    query="${query:0:1000}"
    echo "$query"
}

validate_index_name() {
    local name="$1"
    # Only allow alphanumeric, dash, underscore
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid index name: $name"
        return 1
    fi
    echo "$name"
}

# ============================================
# Statistics
# ============================================
declare -A STATS

stats_init() {
    STATS[files_total]=0
    STATS[files_processed]=0
    STATS[files_skipped]=0
    STATS[files_error]=0
    STATS[bytes_processed]=0
    STATS[start_time]=$(date +%s)
}

stats_increment() {
    local key="$1"
    local amount="${2:-1}"
    ((STATS[$key] += amount))
}

stats_report() {
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - STATS[start_time]))

    echo ""
    echo "${BOLD}=== Crawl Statistics ===${NOBOLD}"
    echo "Duration:        ${duration}s"
    echo "Files total:     ${STATS[files_total]}"
    echo "Files processed: ${STATS[files_processed]}"
    echo "Files skipped:   ${STATS[files_skipped]}"
    echo "Files error:     ${STATS[files_error]}"
    if [[ $duration -gt 0 ]]; then
        local rate=$((STATS[files_processed] / duration))
        echo "Processing rate: ${rate} files/sec"
    fi
}

# ============================================
# Initialization
# ============================================
init_crawl() {
    load_config
    trap_setup
    stats_init
}
