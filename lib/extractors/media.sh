#!/bin/bash
# Media extraction functions (images, audio, video)
# Source this after common.sh

# ============================================
# Image Processing
# ============================================
extract_image_metadata() {
    local path="$1"
    identify -verbose "$path" 2>/dev/null | grep -e 'Geometry:' -e 'User Comment:' -e 'EXIF:'
}

extract_image_ocr() {
    local path="$1"
    local langs="${OCR_LANGS:-eng rus}"
    local result=""

    for lang in $langs; do
        local text
        text=$(tesseract "$path" stdout -l "$lang" 2>/dev/null)
        if [[ -n "$text" ]]; then
            result+="$text "
        fi
    done

    echo "$result"
}

save_image_thumbnail() {
    local path="$1"
    local output_dir="$2"
    local size="${IMAGE_THUMBNAIL_SIZE:-640x480}"
    local output_name="${path//\//-}"

    convert -resize "$size" "$path" "$output_dir/$output_name" 2>/dev/null || \
        cp "$path" "$output_dir/$output_name" 2>/dev/null
}

# ============================================
# Audio Processing
# ============================================
extract_audio_metadata() {
    local path="$1"
    ffmpeg -i "$path" 2>&1 | grep -e 'Duration:' -e 'Stream' -e 'title' -e 'artist' -e 'album'
}

extract_audio_transcription() {
    local path="$1"
    local langs="${AUDIO_LANGS:-en-us ru}"
    local result=""

    [[ "${AUDIO_DISABLED:-0}" == "1" ]] && return 0

    for lang in $langs; do
        local text
        text=$(run_with_timeout 300 vosk-transcriber --lang "$lang" --input "$path" 2>/dev/null)
        if [[ -n "$text" ]]; then
            result+="$text "
            break  # Stop after first successful transcription
        fi
    done

    echo "$result"
}

# ============================================
# Video Processing
# ============================================
extract_video_metadata() {
    local path="$1"
    ffmpeg -i "$path" 2>&1 | grep -e 'Duration:' -e 'Stream' -e 'title'
}

extract_video_audio() {
    local path="$1"
    local output_dir="$2"
    ffmpeg -i "$path" -acodec copy -vn "$output_dir/audio.aac" -y 2>/dev/null
}

extract_video_frames() {
    local path="$1"
    local output_dir="$2"
    local max_frames="${3:-10}"
    local fps="${4:-0.1}"

    # Extract limited number of frames
    ffmpeg -i "$path" -vf "fps=$fps" -frames:v "$max_frames" "$output_dir/frame%d.png" -y 2>/dev/null
}

# ============================================
# Combined Extraction
# ============================================
extract_image() {
    local path="$1"
    local output=""

    # Get metadata
    output+=$(extract_image_metadata "$path")
    output+=$'\n'

    # OCR if not disabled
    if [[ "${OCR_DISABLED:-0}" != "1" ]]; then
        output+=$(extract_image_ocr "$path")
    fi

    echo "$output"
}

extract_audio() {
    local path="$1"
    local output=""

    # Get metadata
    output+=$(extract_audio_metadata "$path")
    output+=$'\n'

    # Transcription if not disabled
    if [[ "${AUDIO_DISABLED:-0}" != "1" ]]; then
        output+=$(extract_audio_transcription "$path")
    fi

    echo "$output"
}

extract_video() {
    local path="$1"
    local output_dir="$2"

    # Get metadata
    extract_video_metadata "$path"

    # Extract frames and audio for further processing if OCR enabled
    if [[ "${OCR_DISABLED:-0}" != "1" && -n "$output_dir" ]]; then
        extract_video_audio "$path" "$output_dir"
        extract_video_frames "$path" "$output_dir" "${OCR_MAX_IMAGES:-10}"
    fi
}
