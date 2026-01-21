#!/bin/bash
#
# SMB Share Crawler - Enterprise network crawling
# Mounts and crawls SMB/CIFS shares with depth-based iteration
#
# Usage: ./smb.sh [config_file]
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAWL_DIR="$(dirname "$SCRIPT_DIR")"

# Load common functions if available
if [[ -f "$CRAWL_DIR/lib/common.sh" ]]; then
    source "$CRAWL_DIR/lib/common.sh"
else
    # Minimal fallback
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ============================================
# Load credentials from secure sources
# ============================================
load_smb_credentials() {
    # Try environment variables first (preferred for containers)
    if [[ -n "${SMB_USER:-}" && -n "${SMB_PASS:-}" ]]; then
        DOMAIN="${SMB_DOMAIN:-}"
        USER="$SMB_USER"
        PASS="$SMB_PASS"
        return 0
    fi

    # Try credentials file
    local cred_files=(
        "$HOME/.crawl-credentials.conf"
        "/etc/crawl/credentials.conf"
        "$CRAWL_DIR/config/credentials.conf"
    )

    for cred_file in "${cred_files[@]}"; do
        if [[ -f "$cred_file" ]]; then
            # Check permissions
            local perms
            perms=$(stat -c %a "$cred_file" 2>/dev/null || stat -f %OLp "$cred_file" 2>/dev/null)
            if [[ "${perms: -1}" != "0" ]]; then
                log_warn "Credentials file $cred_file is world-readable!"
            fi

            # Source the file
            source "$cred_file" 2>/dev/null
            DOMAIN="${SMB_DOMAIN:-$DOMAIN}"
            USER="${SMB_USER:-$USER}"
            PASS="${SMB_PASS:-$PASS}"

            if [[ -n "$USER" && -n "$PASS" ]]; then
                return 0
            fi
        fi
    done

    log_error "No SMB credentials found. Set SMB_USER/SMB_PASS environment variables"
    log_error "or create ~/.crawl-credentials.conf with SMB_USER, SMB_PASS, SMB_DOMAIN"
    return 1
}

# ============================================
# Configuration
# ============================================

# Load custom config if provided
CONFIG_FILE="${1:-}"
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults (can be overridden by config or environment)
ROBOT="${ROBOT:-1}"                    # This robot's number (for distributed crawling)
CLUSTER="${CLUSTER:-1}"                # Total robots in cluster
CRAWL_TIME="${CRAWL_TIME:-300}"        # Timeout per share (seconds)
MAX_FILESIZE="${MAX_FILESIZE:--100k}"  # Max file size (find format)
MAX_DEPTH="${MAX_DEPTH:-10}"           # Max directory depth
HOSTS_FILE="${HOSTS_FILE:-smb-hosts.txt}"
SHARES_FILE="${SHARES_FILE:-smb-shares.txt}"
HOSTS_IP_FILE="${HOSTS_IP_FILE:-hosts-ip.txt}"
SMB_VERSIONS="${SMB_VERSIONS:-3.0,2.1,2.0,1.0}"

# Exclusion patterns
EXCLUDE_PATHS="${EXCLUDE_PATHS:-*/Program Files*/*,*/Windows/*,*/AppData/*,*/$RECYCLE.BIN/*}"

# Load credentials
load_smb_credentials || exit 1

# ============================================
# Helper functions
# ============================================

# Try mounting with different SMB versions
try_mount() {
    local ip="$1"
    local share="$2"
    local mountpoint="$3"
    local timeout="${MOUNT_TIMEOUT:-10}"

    IFS=',' read -ra versions <<< "$SMB_VERSIONS"
    for vers in "${versions[@]}"; do
        if timeout "$timeout" mount.cifs "//$ip/$share" "$mountpoint" \
            -o "ro,dom=$DOMAIN,user=$USER,pass=$PASS,vers=$vers" 2>/dev/null; then
            log_info "Mounted //$ip/$share (SMB $vers)"
            return 0
        fi
    done

    log_warn "Failed to mount //$ip/$share"
    return 1
}

# Cleanup function
cleanup_mount() {
    local mountpoint="$1"
    sudo umount "$mountpoint" 2>/dev/null
    rmdir "$mountpoint" 2>/dev/null
    rmdir "$(dirname "$mountpoint")" 2>/dev/null
}

# Resolve IP to hostname
resolve_host() {
    local ip="$1"
    if [[ -f "$HOSTS_IP_FILE" ]]; then
        grep -e " $ip$" "$HOSTS_IP_FILE" 2>/dev/null | awk '{print $1}' | head -n 1
    fi
}

# ============================================
# Phase 1: Discover shares
# ============================================
discover_shares() {
    log_info "Discovering SMB shares..."

    if [[ ! -f "$HOSTS_FILE" ]]; then
        log_error "Hosts file not found: $HOSTS_FILE"
        return 1
    fi

    local total_hosts
    total_hosts=$(wc -l < "$HOSTS_FILE")
    local processed=0

    # Process hosts assigned to this robot
    while read -r ip; do
        ((processed++))

        # Skip if not assigned to this robot (for distributed crawling)
        if (( (processed - ROBOT) % CLUSTER != 0 )); then
            continue
        fi

        log_info "[$processed/$total_hosts] Checking $ip..."

        # List shares
        smbclient -U "$DOMAIN/$USER%$PASS" -L "$ip" 2>/dev/null | \
            grep 'Disk' | \
            sed -rn 's/^\s+(.+)\s+Disk.*/\1/p' | \
            grep -Fv -e 'IPC$' -e 'print$' -e 'ADMIN$' | \
            while read -r share; do
                # Test if accessible
                if smbclient -U "$DOMAIN/$USER%$PASS" "//$ip/$share" -c 'q' >/dev/null 2>&1; then
                    echo -e "$ip\t$share"
                    log_info "  Found: $share"
                fi
            done

    done < "$HOSTS_FILE" > "$SHARES_FILE"

    local share_count
    share_count=$(wc -l < "$SHARES_FILE" 2>/dev/null || echo 0)
    log_info "Discovered $share_count accessible shares"
}

# ============================================
# Phase 2: Crawl all files
# ============================================
crawl_all() {
    log_info "Starting full crawl..."

    local output_dir="smb-all"
    mkdir -p "$output_dir"
    cd "$output_dir" || exit 1

    # Build exclusion arguments
    local exclude_args=()
    IFS=',' read -ra patterns <<< "$EXCLUDE_PATHS"
    for pattern in "${patterns[@]}"; do
        exclude_args+=(-not -ipath "$pattern")
    done

    # Crawl at each depth level
    for depth in $(seq 1 "$MAX_DEPTH"); do
        log_info "Depth level $depth/$MAX_DEPTH"

        while IFS=$'\t' read -r ip share; do
            # Resolve hostname
            local host
            host=$(resolve_host "$ip")
            host="${host:-$ip}"

            log_info "Crawling //$ip/$share (as $host)..."

            # Create mount point
            local mountpoint="smb/$host/$share"
            mkdir -p "$mountpoint"

            # Mount and crawl
            if sudo try_mount "$ip" "$share" "$mountpoint"; then
                timeout "$CRAWL_TIME" "$CRAWL_DIR/crawl.sh" "$mountpoint" \
                    -mindepth "$depth" -maxdepth "$depth" \
                    -size "$MAX_FILESIZE" \
                    "${exclude_args[@]}" || true

                cleanup_mount "$mountpoint"
            fi

        done < "../$SHARES_FILE"
    done

    cd - > /dev/null
    log_info "Full crawl complete"
}

# ============================================
# Phase 3: Crawl recent files (incremental)
# ============================================
crawl_recent() {
    local hours="${1:-24}"
    log_info "Starting incremental crawl (last $hours hours)..."

    local output_dir="smb-new"
    mkdir -p "$output_dir"
    cd "$output_dir" || exit 1

    # Build exclusion arguments
    local exclude_args=()
    IFS=',' read -ra patterns <<< "$EXCLUDE_PATHS"
    for pattern in "${patterns[@]}"; do
        exclude_args+=(-not -ipath "$pattern")
    done

    local since
    since=$(date +'%Y-%m-%d %H:%M:%S' -d "-${hours} hours")

    for depth in $(seq 1 "$MAX_DEPTH"); do
        while IFS=$'\t' read -r ip share; do
            local host
            host=$(resolve_host "$ip")
            host="${host:-$ip}"

            log_info "Incremental: //$ip/$share depth=$depth"

            local mountpoint="smb/$host/$share"
            mkdir -p "$mountpoint"

            if sudo try_mount "$ip" "$share" "$mountpoint"; then
                timeout "$CRAWL_TIME" "$CRAWL_DIR/crawl.sh" "$mountpoint" \
                    -newermt "$since" \
                    -mindepth "$depth" -maxdepth "$depth" \
                    -size "$MAX_FILESIZE" \
                    "${exclude_args[@]}" || true

                cleanup_mount "$mountpoint"

                # Clean session file for fresh re-crawl next time
                rm -f ".smb_${host}_${share}.session.db" 2>/dev/null
            fi

        done < "../$SHARES_FILE"
    done

    cd - > /dev/null
    log_info "Incremental crawl complete"
}

# ============================================
# Main
# ============================================
usage() {
    cat <<EOF
Usage: $0 [command] [options]

Commands:
  discover    Discover accessible SMB shares
  all         Crawl all files (full scan)
  recent [N]  Crawl files modified in last N hours (default: 24)
  full        Run discover + all

Environment variables:
  SMB_DOMAIN     Domain name
  SMB_USER       Username
  SMB_PASS       Password
  ROBOT          This robot's number (default: 1)
  CLUSTER        Total robots in cluster (default: 1)
  CRAWL_TIME     Timeout per share in seconds (default: 300)
  MAX_FILESIZE   Max file size, find format (default: -100k)
  MAX_DEPTH      Max directory depth (default: 10)

Files:
  smb-hosts.txt   Input: list of IPs to scan
  smb-shares.txt  Output: discovered shares
  hosts-ip.txt    Optional: IP to hostname mapping

EOF
    exit 1
}

case "${1:-full}" in
    discover)
        discover_shares
        ;;
    all)
        crawl_all
        ;;
    recent)
        crawl_recent "${2:-24}"
        ;;
    full)
        discover_shares
        crawl_all
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        ;;
esac

log_info "SMB crawl finished"
