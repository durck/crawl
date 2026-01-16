#!/bin/bash

# Crawl Multi-Threaded с поддержкой сессий
# Полный функционал оригинального crawl.sh + многопоточность
#
# Использование: ./crawl_mt.sh <folder> [threads] [find options]
# Пример: ./crawl_mt.sh smb/server/share 8 -size -10M -not -ipath '*/Windows/*'

RED=$'\x1b[31m'
GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
GREY=$'\x1b[90m'
RESET=$'\x1b[39m'

TARGET="$1"
THREADS="${2:-4}"
shift 2 2>/dev/null
OPTS="$@"

if [ -z "$TARGET" ]; then
    echo "$0 <folder> [threads] [find options]"
    echo ""
    echo "Examples:"
    echo "  $0 smb/server/share 8 -size -10M"
    echo "  $0 folder/ 4 -size -10M -not -ipath '*/Windows/*'"
    echo "  $0 folder/ 12 -iname '*.doc' -o -iname '*.pdf'"
    echo ""
    echo "Options:"
    echo "  folder     - target folder to crawl (relative path only)"
    echo "  threads    - number of parallel workers (default: 4)"
    echo "  find opts  - any valid find(1) options"
    echo ""
    echo "Environment variables:"
    echo "  OCR_MIN_TEXT=100    - min chars from pdf2txt before skipping image OCR"
    echo "  OCR_MAX_IMAGES=0    - max images to OCR per document (0 = unlimited)"
    echo "  OCR_DISABLED=1      - completely disable OCR for images in documents"
    echo "  IMAGES=/path        - save image thumbnails to this folder"
    echo "  EXCLUDE_DIRS=a,b,c  - skip folders containing these words (comma-separated)"
    exit 1
fi

# Проверка относительного пути
if [[ ${TARGET:0:1} = '.' || ${TARGET:0:1} = '/' ]]; then
    echo "only relative direct path: $0 path/to/folder"
    exit 1
fi

# Проверка зависимостей
if ! command -v parallel &> /dev/null; then
    echo "${RED}[!] GNU Parallel not found. Install: sudo apt install parallel${RESET}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEX="${TARGET//\//_}.csv"
SESSION_FILE=".${TARGET//\//_}.sess"
LOCK_FILE="/tmp/.crawl_mt_${TARGET//\//_}.lock"

# Извлекаем сервер и шару из пути (smb/server/share/... -> server, share)
# Поддерживаемые форматы: smb/server/share, nfs/server/export, ftp/server/path
IFS='/' read -ra PATH_PARTS <<< "$TARGET"
PROTO="${PATH_PARTS[0]}"
SERVER="${PATH_PARTS[1]:-}"
SHARE="${PATH_PARTS[2]:-}"

# Формируем URL для браузера
case "$PROTO" in
    smb)
        # file://server/share работает в Windows и большинстве браузеров
        BASE_URL="file://${SERVER}/${SHARE}"
        ;;
    nfs)
        BASE_URL="file://${SERVER}/${SHARE}"
        ;;
    ftp)
        BASE_URL="${PROTO}://${SERVER}/${SHARE}"
        ;;
    http|https)
        # Для веб-сайтов URL уже полный, server/share не нужны для отображения
        BASE_URL="${PROTO}://${SERVER}/${SHARE}"
        SERVER=""
        SHARE=""
        ;;
    *)
        BASE_URL=""
        ;;
esac

# Создаём файлы
touch "$LOCK_FILE"
touch "$SESSION_FILE"

# Настройки OCR
OCR_LANGS="eng rus"
AUDIO_LANGS="en-us ru"
OCR_MIN_TEXT="${OCR_MIN_TEXT:-100}"      # Минимум символов из pdf2txt, чтобы пропустить OCR картинок
OCR_MAX_IMAGES="${OCR_MAX_IMAGES:-0}"    # Максимум картинок для OCR (0 = без лимита)
OCR_DISABLED="${OCR_DISABLED:-0}"        # 1 = полностью отключить OCR картинок из документов

# Построение фильтра исключений для find
EXCLUDE_FILTER=""
if [ -n "$EXCLUDE_DIRS" ]; then
    IFS=',' read -ra EXCLUDE_WORDS <<< "$EXCLUDE_DIRS"
    for word in "${EXCLUDE_WORDS[@]}"; do
        EXCLUDE_FILTER="$EXCLUDE_FILTER -not -ipath '*${word}*'"
    done
fi

# Функция escape для CSV
escape_csv() {
    printf '"'
    tr -d '\0,"\r\n' | tr -s ' '
    printf '"'
}

# Атомарная проверка и резервирование файла (возвращает 0 если можно обрабатывать, 1 если уже занят)
try_claim_file() {
    local path="$1"
    (
        flock -x 200
        if fgrep -q "[$path]" "$SESSION_FILE" 2>/dev/null; then
            exit 1  # уже обработан
        fi
        echo "[$path]" >> "$SESSION_FILE"
        exit 0  # зарезервировали
    ) 200>"$LOCK_FILE"
}

# Запись в CSV (thread-safe)
write_to_csv() {
    local data="$1"
    (
        flock -x 200
        [ -s "$INDEX" ] && printf "\n" >> "$INDEX"
        printf '%s' "$data" >> "$INDEX"
    ) 200>"$LOCK_FILE"
}

# Сохранение миниатюры изображения
save_image() {
    local path="$1"
    local SIZE='640x480'
    if [ -n "$IMAGES" ]; then
        convert -resize $SIZE "$path" "$IMAGES/${path//\//-}" 2>/dev/null || cp "$path" "$IMAGES/${path//\//-}" 2>/dev/null
    fi
}

# Обработка вложенных файлов (архивы, медиа из документов)
# $1 = tempdir, $2 = max_files (опционально, 0 = без лимита)
process_nested() {
    local tempdir="$1"
    local max_files="${2:-0}"
    local count=0

    if [ -d "$tempdir" ] && [ "$(ls -A "$tempdir" 2>/dev/null)" ]; then
        find "$tempdir" -type f 2>/dev/null | while read nested_file; do
            if [ "$max_files" -gt 0 ] && [ "$count" -ge "$max_files" ]; then
                echo "${YELLOW}  [!] Limit $max_files files reached, skipping rest${RESET}"
                break
            fi
            process_single_file "$nested_file"
            ((count++))
        done
    fi
}

# Основная функция обработки одного файла
process_single_file() {
    local path="$1"

    # Атомарная проверка и резервирование
    if ! try_claim_file "$path"; then
        echo "${GREY}$path${RESET}"
        return 0
    fi

    local filename=$(basename "$path")
    filename=${filename%\?*}
    local ext=${filename##*.}
    [[ "$filename" = "$ext" ]] && ext=''

    local mime=$(file -b --mime-type "$path" 2>/dev/null)
    local timestamp=$(date +%s)
    local type=""
    local content=""
    local temp=""

    # Обработка по MIME-типу
    case "$mime" in
        */*html*|application/javascript)
            type="html"
            local codepage=$(uchardet "$path" 2>/dev/null)
            content=$(cat "$path" 2>/dev/null | iconv -f "${codepage:-UTF-8}" 2>/dev/null | lynx -nolist -dump -stdin 2>/dev/null | escape_csv)
            echo "${GREEN}$path [html]${RESET}"
            ;;

        text/*|*/*script|*/xml|*/json|*-ini)
            type="text"
            local codepage=$(uchardet "$path" 2>/dev/null)
            content=$(cat "$path" 2>/dev/null | iconv -f "${codepage:-UTF-8}" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [text]${RESET}"
            ;;

        application/msword)
            type="word"
            content=$(catdoc "$path" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [word]${RESET}"
            ;;

        application/vnd.openxmlformats-officedocument.wordprocessingml.document)
            type="word"
            local raw_content=$(unzip -p "$path" 2>/dev/null | grep -a '<w:r' | sed 's/<w:p[^<\/]*>/ /g' | sed 's/<[^<]*>//g' | grep -a -v '^[[:space:]]*$' | sed G)
            content=$(echo "$raw_content" | escape_csv)
            echo "${GREEN}$path [word]${RESET}"
            # Извлечение медиа из docx (только если мало текста)
            if [ "$OCR_DISABLED" != "1" ] && [ ${#raw_content} -lt "$OCR_MIN_TEXT" ]; then
                if unzip -l "$path" 2>/dev/null | grep -q 'word/media/'; then
                    temp=$(mktemp -d)
                    unzip -q "$path" 'word/media/*' -d "$temp" 2>/dev/null
                    process_nested "$temp" "$OCR_MAX_IMAGES"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.ms-excel)
            type="excel"
            content=$(xls2csv -x "$path" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [excel]${RESET}"
            ;;

        application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)
            type="excel"
            local raw_content=$(unzip -p "$path" 2>/dev/null | grep -a -e '<si><t' -e '<vt:lpstr>' | sed 's/<[^<\/]*>/ /g' | sed 's/<[^<]*>//g')
            content=$(echo "$raw_content" | escape_csv)
            echo "${GREEN}$path [excel]${RESET}"
            # Извлечение медиа из xlsx (только если мало текста)
            if [ "$OCR_DISABLED" != "1" ] && [ ${#raw_content} -lt "$OCR_MIN_TEXT" ]; then
                if unzip -l "$path" 2>/dev/null | grep -q 'xl/media/'; then
                    temp=$(mktemp -d)
                    unzip -q "$path" 'xl/media/*' -d "$temp" 2>/dev/null
                    process_nested "$temp" "$OCR_MAX_IMAGES"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.openxmlformats-officedocument.presentationml.presentation)
            type="powerpoint"
            local raw_content=$(unzip -qc "$path" 'ppt/slides/slide*.xml' 2>/dev/null | grep -oP '(?<=\<a:t\>).*?(?=\</a:t\>)')
            content=$(echo "$raw_content" | escape_csv)
            echo "${GREEN}$path [powerpoint]${RESET}"
            # Извлечение медиа из pptx (только если мало текста)
            if [ "$OCR_DISABLED" != "1" ] && [ ${#raw_content} -lt "$OCR_MIN_TEXT" ]; then
                if unzip -l "$path" 2>/dev/null | grep -q 'ppt/media/'; then
                    temp=$(mktemp -d)
                    unzip -q "$path" 'ppt/media/*' -d "$temp" 2>/dev/null
                    process_nested "$temp" "$OCR_MAX_IMAGES"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/vnd.oasis.opendocument.graphics|application/vnd.ms-visio.drawing.main*)
            type="visio"
            # LibreOffice
            local lo_content=$(unzip -qc "$path" 'content.xml' 2>/dev/null | grep -oP '(?<=\<text:p\>).*?(?=\</text:p\>)')
            # Microsoft
            local ms_content=""
            for page in $(unzip -qq -l "$path" 'visio/pages/*.xml' 2>/dev/null | awk '{print $NF}'); do
                ms_content+=$(unzip -qc "$path" "$page" 2>/dev/null | xq 2>/dev/null | grep -e '"#text":' -e '"@Name":' | cut -d : -f 2- | tr -d '"')
            done
            local raw_content="${lo_content}${ms_content}"
            content=$(echo "$raw_content" | escape_csv)
            echo "${GREEN}$path [visio]${RESET}"
            # Извлечение картинок (только если мало текста)
            if [ "$OCR_DISABLED" != "1" ] && [ ${#raw_content} -lt "$OCR_MIN_TEXT" ]; then
                if unzip -l "$path" 2>/dev/null | grep 'Pictures/' | grep -qv 'TablePreview1.svm'; then
                    temp=$(mktemp -d)
                    unzip -q "$path" 'Pictures/*.jpg' -d "$temp" 2>/dev/null
                    process_nested "$temp" "$OCR_MAX_IMAGES"
                    rm -rf "$temp"
                fi
                if unzip -l "$path" 2>/dev/null | grep -q 'visio/media/'; then
                    temp=$(mktemp -d)
                    unzip -q "$path" 'visio/media/*' -d "$temp" 2>/dev/null
                    process_nested "$temp" "$OCR_MAX_IMAGES"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/pdf)
            type="pdf"
            local raw_content=$(pdf2txt "$path" 2>/dev/null)
            content=$(echo "$raw_content" | escape_csv)
            echo "${GREEN}$path [pdf]${RESET}"
            # Извлечение изображений из PDF ТОЛЬКО если pdf2txt дал мало текста (скан)
            if [ "$OCR_DISABLED" != "1" ] && [ ${#raw_content} -lt "$OCR_MIN_TEXT" ]; then
                local img_count=$(pdfimages -list "$path" 2>/dev/null | tail -n +3 | wc -l)
                if [ "$img_count" -ge 1 ]; then
                    echo "${YELLOW}  [*] PDF scan detected, OCR ${img_count} images (max ${OCR_MAX_IMAGES})...${RESET}"
                    temp=$(mktemp -d)
                    pdfimages -all "$path" "$temp/img" 2>/dev/null
                    process_nested "$temp" "$OCR_MAX_IMAGES"
                    rm -rf "$temp"
                fi
            fi
            ;;

        application/x-ms-shortcut)
            type="lnk"
            content=$(lnkinfo "$path" 2>/dev/null | grep -e 'String' | cut -d ' ' -f 2- | escape_csv)
            echo "${GREEN}$path [lnk]${RESET}"
            ;;

        application/x-executable|application/*microsoft*-executable|application/x*dos*)
            type="executable"
            content=$(rabin2 -qq -z "$path" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [exe]${RESET}"
            ;;

        application/x-object|application/x-sharedlib|application/x-pie-executable)
            type="executable"
            content=$(rabin2 -qq -z "$path" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [elf]${RESET}"
            ;;

        image/*)
            type="image"
            local img_meta=$(identify -verbose "$path" 2>/dev/null | grep -e 'Geometry:' -e 'User Comment:')
            local ocr_text=""
            for lang in $OCR_LANGS; do
                ocr_text+=$(tesseract "$path" stdout -l $lang 2>/dev/null)
            done
            content=$(echo "${img_meta}${ocr_text}" | escape_csv)
            save_image "$path"
            echo "${GREEN}$path [image]${RESET}"
            ;;

        audio/*)
            type="audio"
            local audio_meta=$(ffmpeg -i "$path" 2>&1 | grep -e 'Duration:')
            local transcription=""
            for lang in $AUDIO_LANGS; do
                transcription+=$(vosk-transcriber --lang $lang --input "$path" 2>/dev/null)
            done
            content=$(echo "${audio_meta}${transcription}" | escape_csv)
            echo "${GREEN}$path [audio]${RESET}"
            ;;

        video/*)
            type="video"
            content=$(ffmpeg -i "$path" 2>&1 | grep -e 'Duration:' -e 'Stream' | escape_csv)
            echo "${GREEN}$path [video]${RESET}"
            # Извлечение аудио и кадров (только если OCR включен)
            if [ "$OCR_DISABLED" != "1" ]; then
                temp=$(mktemp -d)
                ffmpeg -i "$path" -acodec copy "$temp/audio.aac" 2>/dev/null
                # Ограничиваем до 10 кадров максимум (каждые 10 сек первых 100 сек)
                ffmpeg -i "$path" -vf "fps=0.1" -frames:v 10 "$temp/frame%d.png" 2>/dev/null
                process_nested "$temp" "$OCR_MAX_IMAGES"
                rm -rf "$temp"
            fi
            ;;

        application/x-ole-storage)
            type="thumbsdb"
            content='""'
            echo "${GREEN}$path [thumbsdb]${RESET}"
            temp=$(mktemp -d)
            vinetto "$path" -o "$temp" 2>/dev/null
            process_nested "$temp" "$OCR_MAX_IMAGES"
            rm -rf "$temp"
            ;;

        application/*compressed*|application/*zip*|application/*rar*|application/*tar*|application/*gzip*|application/*-msi|*/java-archive|application/x-archive)
            type="archive"
            content=$(7z l -p '' "$path" 2>/dev/null | tail -n +13 | escape_csv)
            echo "${GREEN}$path [archive]${RESET}"
            temp=$(mktemp -d)
            7z x -p '' "$path" -o"$temp" 2>/dev/null
            process_nested "$temp"  # архивы без лимита
            rm -rf "$temp"
            ;;

        application/x-installshield)
            type="archive"
            content='""'
            echo "${GREEN}$path [cab]${RESET}"
            temp=$(mktemp -d)
            cabextract -d "$temp" "$path" 2>/dev/null
            process_nested "$temp"
            rm -rf "$temp"
            ;;

        application/x-rpm)
            type="package"
            content='""'
            echo "${GREEN}$path [rpm]${RESET}"
            temp=$(mktemp -d)
            cd "$temp" && rpm2cpio "$path" 2>/dev/null | cpio -idm 2>/dev/null && cd - >/dev/null
            process_nested "$temp"
            rm -rf "$temp"
            ;;

        application/vnd.debian.binary-package)
            type="package"
            content='""'
            echo "${GREEN}$path [deb]${RESET}"
            temp=$(mktemp -d)
            dpkg --extract "$path" "$temp" 2>/dev/null
            process_nested "$temp"
            rm -rf "$temp"
            ;;

        application/x-bytecode.python)
            type="bytecode"
            content=$(pycdc "$path" 2>/dev/null | tail -n +5 | escape_csv)
            echo "${GREEN}$path [bytecode]${RESET}"
            ;;

        application/x-ms-evtx)
            type="winevent"
            content=$(evtx "$path" -o jsonl 2>/dev/null | escape_csv)
            echo "${GREEN}$path [evtx]${RESET}"
            ;;

        application/vnd.ms-outlook)
            type="message"
            temp=$(mktemp -d)
            msgconvert --outfile "$temp/out.eml" "$path" 2>/dev/null
            content=$(mu view "$temp/out.eml" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [message]${RESET}"
            munpack -t -f -C "$temp" 'out.eml' 2>/dev/null
            rm -f "$temp/out.eml"
            process_nested "$temp"
            rm -rf "$temp"
            ;;

        message/*)
            type="message"
            content=$(mu view "$path" 2>/dev/null | escape_csv)
            echo "${GREEN}$path [message]${RESET}"
            temp=$(mktemp -d)
            cp "$path" "$temp/"
            munpack -t -f -C "$temp" "$(basename "$path")" 2>/dev/null
            rm -f "$temp/$(basename "$path")"
            process_nested "$temp"
            rm -rf "$temp"
            ;;

        application/*sqlite3)
            type="sqlite"
            content=$(sqlite3 "$path" '.dump' 2>/dev/null | escape_csv)
            echo "${GREEN}$path [sqlite]${RESET}"
            ;;

        application/vnd.tcpdump.pcap)
            type="pcap"
            content=$(tcpdump -r "$path" -nn -A 2>/dev/null | escape_csv)
            echo "${GREEN}$path [pcap]${RESET}"
            ;;

        application/x-raw-disk-image|application/x-qemu-disk|application/x-virtualbox-vdi|application/x-virtualbox-vmdk)
            type="disk"
            content='""'
            echo "${YELLOW}$path [disk] - skipped (use original crawl.sh)${RESET}"
            ;;

        application/octet-stream)
            type="raw"
            content='""'
            echo "${GREEN}$path [raw]${RESET}"
            ;;

        *)
            # Пробуем как текст
            if file "$path" 2>/dev/null | grep -q text; then
                type="text"
                content=$(cat "$path" 2>/dev/null | escape_csv)
                echo "${GREEN}$path [text]${RESET}"
            else
                type="unknown"
                content='""'
                echo "${RED}$path [unknown]${RESET}"
                echo "$path $mime" >> unknown_mime.log
            fi
            ;;
    esac

    # Формируем полный путь (заменяем smb/server/share на //server/share)
    local full_path="$path"
    if [ -n "$BASE_URL" ]; then
        # Убираем префикс proto/server/share и заменяем на BASE_URL
        local rel_path="${path#*/*/}"  # убираем первые два компонента (proto/server)
        rel_path="${rel_path#*/}"       # убираем третий компонент (share)
        full_path="${BASE_URL}/${rel_path}"
    fi

    # Записываем в CSV: timestamp,fullpath,relpath,server,share,ext,type,content
    local csv_line="${timestamp},\"${full_path}\",\"${path}\",\"${SERVER}\",\"${SHARE}\",\"${ext}\",\"${type}\",${content}"
    write_to_csv "$csv_line"
}

# Экспорт для parallel
export -f escape_csv try_claim_file write_to_csv save_image process_nested process_single_file
export SESSION_FILE INDEX LOCK_FILE IMAGES
export SERVER SHARE BASE_URL
export RED GREEN YELLOW GREY RESET
export OCR_LANGS AUDIO_LANGS OCR_MIN_TEXT OCR_MAX_IMAGES OCR_DISABLED

# Информация о сессии
if [ -s "$SESSION_FILE" ]; then
    DONE_COUNT=$(wc -l < "$SESSION_FILE")
    echo "${YELLOW}[*] Resuming session: $DONE_COUNT files already processed${RESET}"
else
    echo "[*] Starting new session"
fi

# Подсчёт файлов
echo "[*] Scanning $TARGET ..."
TOTAL_FILES=$(eval "find \"$TARGET\" $EXCLUDE_FILTER $OPTS -type f 2>/dev/null" | wc -l)
echo "[*] Found $TOTAL_FILES files"
echo "[*] Using $THREADS threads"
echo "[*] OCR settings: min_text=$OCR_MIN_TEXT, max_images=$OCR_MAX_IMAGES, disabled=$OCR_DISABLED"
[ -n "$EXCLUDE_DIRS" ] && echo "[*] Excluding dirs: $EXCLUDE_DIRS"
echo "[*] Index: $INDEX"
echo "[*] Session: $SESSION_FILE"
echo ""

# Запуск параллельной обработки (--line-buffer предотвращает перемешивание строк)
eval "find \"$TARGET\" $EXCLUDE_FILTER $OPTS -type f 2>/dev/null" | \
    parallel --line-buffer -j "$THREADS" process_single_file {}

# Очистка
rm -f "$LOCK_FILE"

# Статистика
PROCESSED=$(wc -l < "$SESSION_FILE" 2>/dev/null || echo 0)
CSV_LINES=$(wc -l < "$INDEX" 2>/dev/null || echo 0)
echo ""
echo "${GREEN}[+] Done!${RESET}"
echo "    Processed: $PROCESSED files"
echo "    CSV lines: $CSV_LINES"
echo "    Index: $INDEX"
echo "    Session: $SESSION_FILE"
