#!/bin/bash
#
# Crawl - Document crawler and text extractor
# Single-threaded version with session recovery
#
# Usage: ./crawl.sh <folder> [find options]
# Example: ./crawl.sh smb/server/share -size -10M -not -ipath '*/Windows/*'
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
Usage: $0 <folder> [find options]

Crawl a directory and extract text from documents.

Examples:
  $0 folder/
  $0 smb/server/share -size -10M -not -iname '*.wav'
  $0 http/example.com/ -newermt '2024-01-01'

Options (via environment or config):
  MAX_FILESIZE      Maximum file size (default: 100M)
  OCR_DISABLED=1    Disable OCR for images
  OCR_LANGS         OCR languages (default: "eng rus")
  IMAGES=/path      Save image thumbnails
  EXCLUDE_DIRS      Comma-separated dirs to skip
  LOG_LEVEL         DEBUG, INFO, WARN, ERROR

Output:
  Creates <folder>.csv with extracted content
  Session file .<folder>.sess for resume support

EOF
    exit 1
}

# ============================================
# Arguments
# ============================================
[[ $# -lt 1 ]] && usage

TARGET="$1"
shift
FIND_OPTS=("$@")

# Validate and normalize path
validate_path "$TARGET" || exit 1
TARGET=$(sanitize_path "$TARGET")
# Convert to absolute path if relative
[[ "${TARGET:0:1}" != "/" ]] && TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || TARGET="$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")"

# ============================================
# Setup
# ============================================
INDEX="${TARGET//\//_}.csv"
SESSION_DB=".${TARGET//\//_}${SESSION_DB_SUFFIX:-.session.db}"
DEDUPE_DB=".${TARGET//\//_}.dedupe.db"
CURRENT_DEPTH=0

# Parse target path for URL generation
parse_crawl_path "$TARGET"

# Initialize session
session_init "$SESSION_DB"
DONE_COUNT=$(session_count "$SESSION_DB")

if [[ $DONE_COUNT -gt 0 ]]; then
    log_info "Resuming session: $DONE_COUNT files already processed"
else
    log_info "Starting new session"
fi

# Initialize deduplication if enabled
if [[ "${DEDUPE_ENABLED:-0}" == "1" ]]; then
    dedupe_init "$DEDUPE_DB"
    log_info "Deduplication enabled (algorithm: ${DEDUPE_HASH:-md5})"
fi

# Build exclusion filter
EXCLUDE_FILTER=()
if [[ -n "${EXCLUDE_DIRS:-}" ]]; then
    IFS=',' read -ra exclude_list <<< "$EXCLUDE_DIRS"
    for dir in "${exclude_list[@]}"; do
        EXCLUDE_FILTER+=(-not -ipath "*${dir}*")
    done
    log_info "Excluding directories: $EXCLUDE_DIRS"
fi

log_info "Target: $TARGET"
log_info "Index: $INDEX"
log_info "Session: $SESSION_DB"

# ============================================
# CSV Writing (buffered)
# ============================================
CSV_BUFFER=""

flush_csv_buffer() {
    if [[ -n "$CSV_BUFFER" ]]; then
        echo -e "$CSV_BUFFER" >> "$INDEX"
        CSV_BUFFER=""
    fi
}

write_csv_line() {
    local line="$1"
    CSV_BUFFER+="${line}\n"

    # Flush if buffer exceeds size limit
    if [[ ${#CSV_BUFFER} -gt ${CSV_BUFFER_SIZE:-65536} ]]; then
        flush_csv_buffer
    fi
}

# ============================================
# Nested File Processing (for archives, media)
# ============================================
process_nested_files() {
    local temp_dir="$1"
    local max_files="${2:-0}"
    local parent_depth="${3:-$CURRENT_DEPTH}"
    local parent_path="${4:-}"  # Original parent document path

    # Check recursion depth
    local new_depth=$((parent_depth + 1))
    if [[ $new_depth -gt ${MAX_RECURSION_DEPTH:-5} ]]; then
        log_warn "Max recursion depth reached, skipping nested files"
        return
    fi

    [[ ! -d "$temp_dir" ]] && return
    [[ -z "$(ls -A "$temp_dir" 2>/dev/null)" ]] && return

    local count=0
    while IFS= read -r -d '' nested_file; do
        if [[ $max_files -gt 0 && $count -ge $max_files ]]; then
            log_debug "Nested file limit ($max_files) reached"
            break
        fi

        CURRENT_DEPTH=$new_depth
        PARENT_PATH="$parent_path" process_single_file "$nested_file"
        ((count++))
    done < <(find "$temp_dir" -type f -print0 2>/dev/null)

    CURRENT_DEPTH=$parent_depth
}

# ============================================
# Single File Processing
# ============================================
process_single_file() {
    local path="$1"

    # Check if already processed
    if session_is_done "$SESSION_DB" "$path"; then
        echo "${GREY}[skip] $path${RESET}"
        stats_increment files_skipped
        return 0
    fi

    # Get file info
    local filename
    filename=$(basename "$path")
    filename="${filename%\?*}"
    local ext="${filename##*.}"
    [[ "$filename" == "$ext" ]] && ext=""

    local mime
    mime=$(file -b --mime-type "$path" 2>/dev/null)

    # Deduplication check
    if [[ "${DEDUPE_ENABLED:-0}" == "1" ]]; then
        local hash
        hash=$(compute_hash "$path")
        if dedupe_check "$DEDUPE_DB" "$hash"; then
            log_debug "Duplicate detected: $path (hash: $hash)"
            session_mark_done "$SESSION_DB" "$path"
            stats_increment files_skipped
            return 0
        fi
        dedupe_add "$DEDUPE_DB" "$hash" "$path"
    fi

    local timestamp
    timestamp=$(date +%s)
    local type=""
    local content=""
    local temp=""

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
            local raw_content
            raw_content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_docx "$path")
            content=$(echo "$raw_content" | escape_csv_fast)
            echo "${GREEN}$path [docx]${RESET}"

            # Extract embedded images if text is sparse
            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw_content} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_docx_has_media "$path"; then
                    temp=$(make_temp_dir "docx")
                    cleanup_register "$temp"
                    extract_docx_media "$path" "$temp"
                    process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
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
            local raw_content
            raw_content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_xlsx "$path")
            content=$(echo "$raw_content" | escape_csv_fast)
            echo "${GREEN}$path [xlsx]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw_content} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_xlsx_has_media "$path"; then
                    temp=$(make_temp_dir "xlsx")
                    cleanup_register "$temp"
                    extract_xlsx_media "$path" "$temp"
                    process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.openxmlformats-officedocument.presentationml.presentation)
            type="powerpoint"
            local raw_content
            raw_content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_pptx "$path")
            content=$(echo "$raw_content" | escape_csv_fast)
            echo "${GREEN}$path [pptx]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw_content} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_pptx_has_media "$path"; then
                    temp=$(make_temp_dir "pptx")
                    cleanup_register "$temp"
                    extract_pptx_media "$path" "$temp"
                    process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.oasis.opendocument.*|application/vnd.ms-visio.drawing.main*)
            type="visio"
            local raw_content
            raw_content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_visio "$path")
            content=$(echo "$raw_content" | escape_csv_fast)
            echo "${GREEN}$path [visio/odt]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw_content} -lt ${OCR_MIN_TEXT:-100} ]]; then
                if extract_visio_has_media "$path"; then
                    temp=$(make_temp_dir "visio")
                    cleanup_register "$temp"
                    extract_visio_media "$path" "$temp"
                    process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/pdf)
            type="pdf"
            local raw_content
            raw_content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_pdf "$path")
            content=$(echo "$raw_content" | escape_csv_fast)
            echo "${GREEN}$path [pdf]${RESET}"

            # OCR scanned PDFs
            if [[ "${OCR_DISABLED:-0}" != "1" && ${#raw_content} -lt ${OCR_MIN_TEXT:-100} ]]; then
                local img_count
                img_count=$(extract_pdf_image_count "$path")
                if [[ $img_count -ge 1 ]]; then
                    log_info "  PDF scan detected, OCR $img_count images..."
                    temp=$(make_temp_dir "pdf")
                    cleanup_register "$temp"
                    extract_pdf_images "$path" "$temp"
                    process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
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
            local meta
            meta=$(extract_video_metadata "$path")
            content=$(echo "$meta" | escape_csv_fast)
            echo "${GREEN}$path [video]${RESET}"

            if [[ "${OCR_DISABLED:-0}" != "1" ]]; then
                temp=$(make_temp_dir "video")
                cleanup_register "$temp"
                extract_video "$path" "$temp"
                process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
                rm -rf "$temp"
            fi
            ;;

        application/x-ole-storage)
            type="thumbsdb"
            content=""
            echo "${GREEN}$path [thumbsdb]${RESET}"
            temp=$(make_temp_dir "thumbsdb")
            cleanup_register "$temp"
            extract_thumbsdb "$path" "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path" "${OCR_MAX_IMAGES:-10}" "$CURRENT_DEPTH" "$path"
            rm -rf "$temp"
            ;;

        application/*compressed*|application/*zip*|application/*rar*|application/*tar*|application/*gzip*|application/*-msi|*/java-archive|application/x-archive)
            type="archive"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_archive_list "$path" | escape_csv_fast)
            echo "${GREEN}$path [archive]${RESET}"
            temp=$(make_temp_dir "archive")
            cleanup_register "$temp"
            extract_archive "$path" "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path"
            rm -rf "$temp"
            ;;

        application/x-installshield)
            type="archive"
            content=""
            echo "${GREEN}$path [cab]${RESET}"
            temp=$(make_temp_dir "cab")
            cleanup_register "$temp"
            extract_cab "$path" "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path"
            rm -rf "$temp"
            ;;

        application/x-rpm)
            type="package"
            content=""
            echo "${GREEN}$path [rpm]${RESET}"
            temp=$(make_temp_dir "rpm")
            cleanup_register "$temp"
            extract_rpm "$path" "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path"
            rm -rf "$temp"
            ;;

        application/vnd.debian.binary-package)
            type="package"
            content=""
            echo "${GREEN}$path [deb]${RESET}"
            temp=$(make_temp_dir "deb")
            cleanup_register "$temp"
            extract_deb "$path" "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path"
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
            cleanup_register "$temp"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_msg "$path" "$temp" | escape_csv_fast)
            echo "${GREEN}$path [msg]${RESET}"
            extract_msg_attachments "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path"
            rm -rf "$temp"
            ;;

        message/*)
            type="message"
            content=$(run_with_timeout "$COMMAND_TIMEOUT" extract_eml "$path" | escape_csv_fast)
            echo "${GREEN}$path [eml]${RESET}"
            temp=$(make_temp_dir "eml")
            cleanup_register "$temp"
            extract_eml_attachments "$path" "$temp"
            process_nested_files "$temp" 0 "$CURRENT_DEPTH" "$path"
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
            # Try as text
            if file "$path" 2>/dev/null | grep -q text; then
                type="text"
                content=$(cat "$path" 2>/dev/null | escape_csv_fast)
                echo "${GREEN}$path [text]${RESET}"
            else
                type="unknown"
                content=""
                echo "${RED}$path [unknown: $mime]${RESET}"
                echo "$path $mime" >> unknown_mime.log
                stats_increment files_error
            fi
            ;;
    esac

    # Generate full URL path
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

    # Write CSV line: timestamp,fullpath,relpath,server,share,ext,type,content
    local csv_line="${timestamp},\"${full_path}\",\"${source_path}\",\"${CRAWL_SERVER}\",\"${CRAWL_SHARE}\",\"${ext}\",\"${type}\",\"${content}\""
    write_csv_line "$csv_line"

    # Mark as processed
    session_mark_done "$SESSION_DB" "$path"
    stats_increment files_processed
}

# ============================================
# Main Processing
# ============================================
log_info "Scanning $TARGET..."

# Count total files
TOTAL_FILES=$(find "$TARGET" "${EXCLUDE_FILTER[@]}" "${FIND_OPTS[@]}" -type f 2>/dev/null | wc -l)
log_info "Found $TOTAL_FILES files"
STATS[files_total]=$TOTAL_FILES

# Process files
while IFS= read -r -d '' path; do
    process_single_file "$path"
done < <(find "$TARGET" "${EXCLUDE_FILTER[@]}" "${FIND_OPTS[@]}" -type f -print0 2>/dev/null)

# Flush remaining buffer
flush_csv_buffer

# Report statistics
stats_report

log_info "Index saved to: $INDEX"
log_info "Session saved to: $SESSION_DB"
