#!/bin/bash
#
# Crawl Multi-Threaded - Document crawler with parallel processing
# Uses GNU Parallel for high-performance crawling
#
# Usage: ./crawl_mt.sh <folder> [threads] [find options]
# Example: ./crawl_mt.sh smb/server/share 8 -size -10M -not -ipath '*/Windows/*'
#

set -o pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/extractors/text.sh"
source "$SCRIPT_DIR/lib/extractors/media.sh"

# Initialize
init_crawl

# ============================================
# Usage
# ============================================
usage() {
    cat <<EOF
Usage: $0 <folder> [threads] [find options]

Crawl a directory using multiple threads for faster processing.

Examples:
  $0 smb/server/share 8 -size -10M
  $0 folder/ 4 -not -ipath '*/Windows/*'
  $0 folder/ 12 -iname '*.doc' -o -iname '*.pdf'

Arguments:
  folder    Target folder to crawl (relative or absolute path)
  threads   Number of parallel workers (default: ${DEFAULT_THREADS:-4})
  find opts Any valid find(1) options

Environment variables:
  OCR_MIN_TEXT=100    Min chars from pdf2txt before image OCR
  OCR_MAX_IMAGES=10   Max images to OCR per document (0=unlimited)
  OCR_DISABLED=1      Completely disable OCR
  IMAGES=/path        Save image thumbnails to this folder
  EXCLUDE_DIRS=a,b,c  Skip folders containing these words
  DEDUPE_ENABLED=1    Enable content deduplication
  LOG_LEVEL=DEBUG     Logging level (DEBUG/INFO/WARN/ERROR)

EOF
    exit 1
}

# ============================================
# Arguments
# ============================================
[[ $# -lt 1 ]] && usage

TARGET="$1"
THREADS="${2:-${DEFAULT_THREADS:-4}}"
shift 2 2>/dev/null || shift 1
FIND_OPTS=("$@")

# Validate and normalize path
validate_path "$TARGET" || exit 1
TARGET=$(sanitize_path "$TARGET")
# Convert to absolute path if relative
[[ "${TARGET:0:1}" != "/" ]] && TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || TARGET="$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")"

# Check dependencies
require_cmd parallel "gnu-parallel" || exit 1

# ============================================
# Setup
# ============================================
INDEX="${TARGET//\//_}.csv"
SESSION_DB=".${TARGET//\//_}${SESSION_DB_SUFFIX:-.session.db}"
DEDUPE_DB=".${TARGET//\//_}.dedupe.db"
LOCK_FILE="/tmp/.crawl_mt_${TARGET//\//_}.lock"

# Parse target path
parse_crawl_path "$TARGET"

# Initialize databases
touch "$LOCK_FILE"
session_init "$SESSION_DB"

if [[ "${DEDUPE_ENABLED:-0}" == "1" ]]; then
    dedupe_init "$DEDUPE_DB"
fi

# Build exclusion filter
EXCLUDE_FILTER=""
if [[ -n "${EXCLUDE_DIRS:-}" ]]; then
    IFS=',' read -ra exclude_list <<< "$EXCLUDE_DIRS"
    for dir in "${exclude_list[@]}"; do
        EXCLUDE_FILTER="$EXCLUDE_FILTER -not -ipath '*${dir}*'"
    done
fi

# ============================================
# Thread-safe operations
# ============================================
atomic_session_claim() {
    local path="$1"
    (
        flock -x 200
        if session_is_done "$SESSION_DB" "$path"; then
            exit 1
        fi
        session_mark_done "$SESSION_DB" "$path"
        exit 0
    ) 200>"$LOCK_FILE"
}

atomic_write_csv() {
    local data="$1"
    (
        flock -x 200
        [[ -s "$INDEX" ]] && printf "\n" >> "$INDEX"
        printf '%s' "$data" >> "$INDEX"
    ) 200>"$LOCK_FILE"
}

atomic_dedupe_check() {
    local hash="$1"
    local path="$2"
    (
        flock -x 200
        if dedupe_check "$DEDUPE_DB" "$hash"; then
            exit 1
        fi
        dedupe_add "$DEDUPE_DB" "$hash" "$path"
        exit 0
    ) 200>"$LOCK_FILE"
}

# ============================================
# Process nested files (limited recursion)
# ============================================
process_nested_mt() {
    local temp_dir="$1"
    local max_files="${2:-0}"
    local current_depth="${3:-0}"
    local parent_path="${4:-}"  # Original parent document path

    local new_depth=$((current_depth + 1))
    if [[ $new_depth -gt ${MAX_RECURSION_DEPTH:-5} ]]; then
        echo "${YELLOW}  [!] Max recursion depth reached${RESET}" >&2
        return
    fi

    [[ ! -d "$temp_dir" ]] && return
    [[ -z "$(ls -A "$temp_dir" 2>/dev/null)" ]] && return

    local count=0
    while IFS= read -r -d '' nested; do
        if [[ $max_files -gt 0 && $count -ge $max_files ]]; then
            break
        fi
        CURRENT_DEPTH=$new_depth PARENT_PATH="$parent_path" process_file_mt "$nested"
        ((count++))
    done < <(find "$temp_dir" -type f -print0 2>/dev/null)
}

# ============================================
# Single file processing (for parallel)
# ============================================
process_file_mt() {
    local path="$1"
    local current_depth="${CURRENT_DEPTH:-0}"

    # Atomic claim
    if ! atomic_session_claim "$path"; then
        echo "${GREY}$path${RESET}"
        return 0
    fi

    local filename
    filename=$(basename "$path")
    filename="${filename%\?*}"
    local ext="${filename##*.}"
    [[ "$filename" == "$ext" ]] && ext=""

    local mime
    mime=$(file -b --mime-type "$path" 2>/dev/null)
    local timestamp
    timestamp=$(date +%s)
    local type=""
    local content=""
    local temp=""

    # Deduplication
    if [[ "${DEDUPE_ENABLED:-0}" == "1" ]]; then
        local hash
        hash=$(compute_hash "$path")
        if ! atomic_dedupe_check "$hash" "$path"; then
            echo "${GREY}[dup] $path${RESET}"
            return 0
        fi
    fi

    # Process by MIME type
    case "$mime" in
        */*html*|application/javascript)
            type="html"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_html "$path" | escape_csv_fast)
            echo "${GREEN}$path [html]${RESET}"
            ;;

        text/*|*/*script|*/xml|*/json|*-ini)
            type="text"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_text "$path" | escape_csv_fast)
            echo "${GREEN}$path [text]${RESET}"
            ;;

        application/msword)
            type="word"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_doc "$path" | escape_csv_fast)
            echo "${GREEN}$path [word]${RESET}"
            ;;

        application/vnd.openxmlformats-officedocument.wordprocessingml.document)
            type="word"
            local raw
            raw=$(run_with_timeout "$COMMAND_TIMEOUT" extract_docx "$path")
            content=$(echo "$raw" | escape_csv_fast)
            echo "${GREEN}$path [docx]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_docx_has_media "$path"; then
                    temp=$(make_temp_dir "docx")
                    extract_docx_media "$path" "$temp"
                    process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.ms-excel)
            type="excel"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_xls "$path" | escape_csv_fast)
            echo "${GREEN}$path [xls]${RESET}"
            ;;

        application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)
            type="excel"
            local raw
            raw=$(run_with_timeout "$COMMAND_TIMEOUT" extract_xlsx "$path")
            content=$(echo "$raw" | escape_csv_fast)
            echo "${GREEN}$path [xlsx]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_xlsx_has_media "$path"; then
                    temp=$(make_temp_dir "xlsx")
                    extract_xlsx_media "$path" "$temp"
                    process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.openxmlformats-officedocument.presentationml.presentation)
            type="powerpoint"
            local raw
            raw=$(run_with_timeout "$COMMAND_TIMEOUT" extract_pptx "$path")
            content=$(echo "$raw" | escape_csv_fast)
            echo "${GREEN}$path [pptx]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_pptx_has_media "$path"; then
                    temp=$(make_temp_dir "pptx")
                    extract_pptx_media "$path" "$temp"
                    process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.oasis.opendocument.*|application/vnd.ms-visio.drawing.main*)
            type="visio"
            local raw
            raw=$(run_with_timeout "$COMMAND_TIMEOUT" extract_visio "$path")
            content=$(echo "$raw" | escape_csv_fast)
            echo "${GREEN}$path [visio]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_visio_has_media "$path"; then
                    temp=$(make_temp_dir "visio")
                    extract_visio_media "$path" "$temp"
                    process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/pdf)
            type="pdf"
            local raw
            raw=$(run_with_timeout "$COMMAND_TIMEOUT" extract_pdf "$path")
            content=$(echo "$raw" | escape_csv_fast)
            echo "${GREEN}$path [pdf]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw} -lt ${OCR_MIN_TEXT:-100} ]]; then
                local img_count
                img_count=$(extract_pdf_image_count "$path")
                if [[ $img_count -ge 1 ]]; then
                    echo "${YELLOW}  [*] OCR ${img_count} images...${RESET}"
                    temp=$(make_temp_dir "pdf")
                    extract_pdf_images "$path" "$temp"
                    process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/x-ms-shortcut)
            type="lnk"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_lnk "$path" | escape_csv_fast)
            echo "${GREEN}$path [lnk]${RESET}"
            ;;

        application/x-executable|application/*microsoft*-executable|application/x*dos*|application/x-dosexec)
            type="executable"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_executable "$path" | escape_csv_fast)
            echo "${GREEN}$path [exe]${RESET}"
            ;;

        application/x-object|application/x-sharedlib|application/x-pie-executable)
            type="executable"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_executable "$path" | escape_csv_fast)
            echo "${GREEN}$path [elf]${RESET}"
            ;;

        image/*)
            type="image"
            content=$(run_with_timeout 120 extract_image "$path" | escape_csv_fast)
            [[ -n "${IMAGES:-}" ]] && save_image_thumbnail "$path" "$IMAGES"
            echo "${GREEN}$path [image]${RESET}"
            ;;

        audio/*)
            type="audio"
            content=$(run_with_timeout 300 extract_audio "$path" | escape_csv_fast)
            echo "${GREEN}$path [audio]${RESET}"
            ;;

        video/*)
            type="video"
            content=$(extract_video_metadata "$path" | escape_csv_fast)
            echo "${GREEN}$path [video]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" ]]; then
                temp=$(make_temp_dir "video")
                extract_video "$path" "$temp"
                process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
                rm -rf "$temp"
            fi
            ;;

        application/x-ole-storage)
            type="thumbsdb"
            content=""
            echo "${GREEN}$path [thumbsdb]${RESET}"
            temp=$(make_temp_dir "thumbsdb")
            extract_thumbsdb "$path" "$temp"
            process_nested_mt "$temp" "${OCR_MAX_IMAGES:-10}" "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        application/*compressed*|application/*zip*|application/*rar*|application/*tar*|application/*gzip*|application/*-msi|*/java-archive|application/x-archive)
            type="archive"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_archive_list "$path" | escape_csv_fast)
            echo "${GREEN}$path [archive]${RESET}"
            temp=$(make_temp_dir "archive")
            extract_archive "$path" "$temp"
            process_nested_mt "$temp" 0 "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        application/x-installshield)
            type="archive"
            content=""
            echo "${GREEN}$path [cab]${RESET}"
            temp=$(make_temp_dir "cab")
            extract_cab "$path" "$temp"
            process_nested_mt "$temp" 0 "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        application/x-rpm)
            type="package"
            content=""
            echo "${GREEN}$path [rpm]${RESET}"
            temp=$(make_temp_dir "rpm")
            extract_rpm "$path" "$temp"
            process_nested_mt "$temp" 0 "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        application/vnd.debian.binary-package)
            type="package"
            content=""
            echo "${GREEN}$path [deb]${RESET}"
            temp=$(make_temp_dir "deb")
            extract_deb "$path" "$temp"
            process_nested_mt "$temp" 0 "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        application/x-bytecode.python)
            type="bytecode"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_pyc "$path" | escape_csv_fast)
            echo "${GREEN}$path [pyc]${RESET}"
            ;;

        application/x-ms-evtx)
            type="winevent"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_evtx "$path" | escape_csv_fast)
            echo "${GREEN}$path [evtx]${RESET}"
            ;;

        application/vnd.ms-outlook)
            type="message"
            temp=$(make_temp_dir "msg")
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_msg "$path" "$temp" | escape_csv_fast)
            echo "${GREEN}$path [msg]${RESET}"
            extract_msg_attachments "$temp"
            process_nested_mt "$temp" 0 "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        message/*)
            type="message"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_eml "$path" | escape_csv_fast)
            echo "${GREEN}$path [eml]${RESET}"
            temp=$(make_temp_dir "eml")
            extract_eml_attachments "$path" "$temp"
            process_nested_mt "$temp" 0 "$current_depth" "$path"
            rm -rf "$temp"
            ;;

        application/*sqlite3)
            type="sqlite"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_sqlite "$path" | escape_csv_fast)
            echo "${GREEN}$path [sqlite]${RESET}"
            ;;

        application/vnd.tcpdump.pcap)
            type="pcap"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_pcap "$path" | escape_csv_fast)
            echo "${GREEN}$path [pcap]${RESET}"
            ;;

        application/octet-stream)
            type="raw"
            content=""
            echo "${GREY}$path [raw]${RESET}"
            ;;

        *)
            if file "$path" 2>/dev/null | grep -q text; then
                type="text"
                content=$(cat "$path" 2>/dev/null | escape_csv_fast)
                echo "${GREEN}$path [text]${RESET}"
            else
                type="unknown"
                content=""
                echo "${RED}$path [unknown]${RESET}"
            fi
            ;;
    esac

    # Generate full path URL
    # If processing nested file (from archive/document), use parent path as reference
    local display_path="$path"
    local source_path="$path"

    if [[ -n "${PARENT_PATH:-}" ]]; then
        # This is an embedded file - show parent document path
        local nested_name
        nested_name=$(basename "$path")
        display_path="${PARENT_PATH}#${nested_name}"
        source_path="$PARENT_PATH"
    fi

    local full_path="$display_path"
    if [[ -n "$CRAWL_BASE_URL" && "$source_path" != /tmp/* ]]; then
        local rel="${source_path#*/*/}"
        rel="${rel#*/}"
        full_path="${CRAWL_BASE_URL}/${rel}"
        if [[ -n "${PARENT_PATH:-}" ]]; then
            full_path="${full_path}#$(basename "$path")"
        fi
    fi

    # Write CSV - use source_path for actual file reference
    local csv_line="${timestamp},\"${full_path}\",\"${source_path}\",\"${CRAWL_SERVER}\",\"${CRAWL_SHARE}\",\"${ext}\",\"${type}\",\"${content}\""
    atomic_write_csv "$csv_line"
}

# Export for parallel
export -f process_file_mt process_nested_mt atomic_session_claim atomic_write_csv atomic_dedupe_check
export -f escape_csv_fast make_temp_dir run_with_timeout compute_hash
export -f session_is_done session_mark_done dedupe_check dedupe_add
export -f extract_html extract_text extract_doc extract_docx extract_docx_has_media extract_docx_media
export -f extract_xls extract_xlsx extract_xlsx_has_media extract_xlsx_media
export -f extract_pptx extract_pptx_has_media extract_pptx_media
export -f extract_visio extract_visio_has_media extract_visio_media
export -f extract_pdf extract_pdf_image_count extract_pdf_images
export -f extract_lnk extract_executable extract_archive_list extract_archive
export -f extract_cab extract_rpm extract_deb extract_pyc extract_evtx
export -f extract_msg extract_msg_attachments extract_eml extract_eml_attachments
export -f extract_sqlite extract_pcap extract_thumbsdb
export -f extract_image extract_audio extract_video extract_video_metadata
export -f extract_image_metadata extract_image_ocr save_image_thumbnail
export -f extract_audio_metadata extract_audio_transcription
export -f extract_video_audio extract_video_frames

export SESSION_DB INDEX LOCK_FILE DEDUPE_DB IMAGES
export CRAWL_SERVER CRAWL_SHARE CRAWL_BASE_URL
export RED GREEN YELLOW GREY RESET
export OCR_LANGS AUDIO_LANGS OCR_MIN_TEXT OCR_MAX_IMAGES OCR_DISABLED
export COMMAND_TIMEOUT MAX_RECURSION_DEPTH DEDUPE_ENABLED DEDUPE_HASH
export USE_SQLITE_SESSION

# ============================================
# Session info
# ============================================
DONE_COUNT=$(session_count "$SESSION_DB")
if [[ $DONE_COUNT -gt 0 ]]; then
    log_info "Resuming session: $DONE_COUNT files already processed"
else
    log_info "Starting new session"
fi

# ============================================
# Scan and process
# ============================================
log_info "Scanning $TARGET..."
TOTAL_FILES=$(eval "find \"$TARGET\" $EXCLUDE_FILTER ${FIND_OPTS[*]} -type f 2>/dev/null" | wc -l)

log_info "Found $TOTAL_FILES files"
log_info "Using $THREADS threads"
log_info "OCR: min_text=${OCR_MIN_TEXT:-100}, max_images=${OCR_MAX_IMAGES:-10}, disabled=${OCR_DISABLED:-0}"
[[ -n "${EXCLUDE_DIRS:-}" ]] && log_info "Excluding: $EXCLUDE_DIRS"
log_info "Index: $INDEX"
log_info "Session: $SESSION_DB"
echo ""

# Run parallel processing
eval "find \"$TARGET\" $EXCLUDE_FILTER ${FIND_OPTS[*]} -type f -print0 2>/dev/null" | \
    parallel --null --line-buffer -j "$THREADS" process_file_mt {}

# Cleanup
rm -f "$LOCK_FILE"

# Statistics
PROCESSED=$(session_count "$SESSION_DB")
CSV_LINES=$(wc -l < "$INDEX" 2>/dev/null || echo 0)

echo ""
log_info "Done!"
echo "    Processed: $PROCESSED files"
echo "    CSV lines: $CSV_LINES"
echo "    Index: $INDEX"
