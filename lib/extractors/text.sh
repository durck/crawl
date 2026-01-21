#!/bin/bash
# Text extraction functions for various file types
# Source this after common.sh

# ============================================
# HTML/Web Content
# ============================================
extract_html() {
    local path="$1"
    local codepage
    codepage=$(uchardet "$path" 2>/dev/null || echo "UTF-8")
    iconv -f "$codepage" -t UTF-8 "$path" 2>/dev/null | lynx -nolist -dump -stdin 2>/dev/null
}

# ============================================
# Plain Text
# ============================================
extract_text() {
    local path="$1"
    local codepage
    codepage=$(uchardet "$path" 2>/dev/null || echo "UTF-8")
    iconv -f "$codepage" -t UTF-8 "$path" 2>/dev/null || cat "$path" 2>/dev/null
}

# ============================================
# Microsoft Word (.doc)
# ============================================
extract_doc() {
    local path="$1"
    catdoc "$path" 2>/dev/null
}

# ============================================
# Microsoft Word (.docx)
# ============================================
extract_docx() {
    local path="$1"
    unzip -p "$path" word/document.xml 2>/dev/null | \
        sed 's/<w:p[^>]*>/\n/g' | \
        sed 's/<[^>]*>//g' | \
        grep -v '^[[:space:]]*$'
}

extract_docx_has_media() {
    local path="$1"
    unzip -l "$path" 2>/dev/null | grep -q 'word/media/'
}

extract_docx_media() {
    local path="$1"
    local output_dir="$2"
    unzip -q "$path" 'word/media/*' -d "$output_dir" 2>/dev/null
}

# ============================================
# Microsoft Excel (.xls)
# ============================================
extract_xls() {
    local path="$1"
    xls2csv -x "$path" 2>/dev/null
}

# ============================================
# Microsoft Excel (.xlsx)
# ============================================
extract_xlsx() {
    local path="$1"
    # Extract shared strings and cell values
    {
        unzip -p "$path" xl/sharedStrings.xml 2>/dev/null | \
            grep -oP '(?<=<t[^>]*>)[^<]+'
        unzip -p "$path" xl/worksheets/*.xml 2>/dev/null | \
            grep -oP '(?<=<v>)[^<]+'
    } | sort -u
}

extract_xlsx_has_media() {
    local path="$1"
    unzip -l "$path" 2>/dev/null | grep -q 'xl/media/'
}

extract_xlsx_media() {
    local path="$1"
    local output_dir="$2"
    unzip -q "$path" 'xl/media/*' -d "$output_dir" 2>/dev/null
}

# ============================================
# Microsoft PowerPoint (.pptx)
# ============================================
extract_pptx() {
    local path="$1"
    unzip -qc "$path" 'ppt/slides/slide*.xml' 2>/dev/null | \
        grep -oP '(?<=<a:t>)[^<]+'
}

extract_pptx_has_media() {
    local path="$1"
    unzip -l "$path" 2>/dev/null | grep -q 'ppt/media/'
}

extract_pptx_media() {
    local path="$1"
    local output_dir="$2"
    unzip -q "$path" 'ppt/media/*' -d "$output_dir" 2>/dev/null
}

# ============================================
# OpenDocument/Visio
# ============================================
extract_odt() {
    local path="$1"
    unzip -qc "$path" 'content.xml' 2>/dev/null | \
        sed 's/<text:p[^>]*>/\n/g' | \
        sed 's/<[^>]*>//g' | \
        grep -v '^[[:space:]]*$'
}

extract_visio() {
    local path="$1"
    # LibreOffice format
    local lo_content
    lo_content=$(unzip -qc "$path" 'content.xml' 2>/dev/null | \
        grep -oP '(?<=<text:p>)[^<]*')

    # Microsoft format
    local ms_content=""
    local page
    for page in $(unzip -qq -l "$path" 'visio/pages/*.xml' 2>/dev/null | awk '{print $NF}'); do
        ms_content+=$(unzip -qc "$path" "$page" 2>/dev/null | \
            xq 2>/dev/null | \
            grep -e '"#text":' -e '"@Name":' | \
            cut -d: -f2- | tr -d '"')
    done

    echo "$lo_content"
    echo "$ms_content"
}

extract_visio_has_media() {
    local path="$1"
    unzip -l "$path" 2>/dev/null | grep -E '(Pictures/|visio/media/)' | grep -qv 'TablePreview1.svm'
}

extract_visio_media() {
    local path="$1"
    local output_dir="$2"
    unzip -q "$path" 'Pictures/*.jpg' -d "$output_dir" 2>/dev/null
    unzip -q "$path" 'visio/media/*' -d "$output_dir" 2>/dev/null
}

# ============================================
# PDF
# ============================================
extract_pdf() {
    local path="$1"
    pdf2txt "$path" 2>/dev/null
}

extract_pdf_image_count() {
    local path="$1"
    pdfimages -list "$path" 2>/dev/null | tail -n +3 | wc -l
}

extract_pdf_images() {
    local path="$1"
    local output_dir="$2"
    pdfimages -all "$path" "$output_dir/img" 2>/dev/null
}

# ============================================
# Windows Shortcuts (.lnk)
# ============================================
extract_lnk() {
    local path="$1"
    lnkinfo "$path" 2>/dev/null | grep -e 'String' | cut -d' ' -f2-
}

# ============================================
# Executables (PE/ELF)
# ============================================
extract_executable() {
    local path="$1"
    rabin2 -qq -z "$path" 2>/dev/null
}

# ============================================
# Archives
# ============================================
extract_archive_list() {
    local path="$1"
    7z l -p'' "$path" 2>/dev/null | tail -n +13
}

extract_archive() {
    local path="$1"
    local output_dir="$2"
    7z x -p'' "$path" -o"$output_dir" -y 2>/dev/null
}

extract_cab() {
    local path="$1"
    local output_dir="$2"
    cabextract -d "$output_dir" "$path" 2>/dev/null
}

extract_rpm() {
    local path="$1"
    local output_dir="$2"
    cd "$output_dir" && rpm2cpio "$path" 2>/dev/null | cpio -idm 2>/dev/null
}

extract_deb() {
    local path="$1"
    local output_dir="$2"
    dpkg --extract "$path" "$output_dir" 2>/dev/null
}

# ============================================
# Python Bytecode
# ============================================
extract_pyc() {
    local path="$1"
    pycdc "$path" 2>/dev/null | tail -n +5
}

# ============================================
# Windows Event Log
# ============================================
extract_evtx() {
    local path="$1"
    evtx "$path" -o jsonl 2>/dev/null
}

# ============================================
# Email Messages
# ============================================
extract_msg() {
    local path="$1"
    local output_dir="$2"

    msgconvert --outfile "$output_dir/out.eml" "$path" 2>/dev/null
    mu view "$output_dir/out.eml" 2>/dev/null
}

extract_msg_attachments() {
    local output_dir="$1"
    munpack -t -f -C "$output_dir" 'out.eml' 2>/dev/null
    rm -f "$output_dir/out.eml"
}

extract_eml() {
    local path="$1"
    mu view "$path" 2>/dev/null
}

extract_eml_attachments() {
    local path="$1"
    local output_dir="$2"
    local filename
    filename=$(basename "$path")
    cp "$path" "$output_dir/"
    munpack -t -f -C "$output_dir" "$filename" 2>/dev/null
    rm -f "$output_dir/$filename"
}

# ============================================
# SQLite Database
# ============================================
extract_sqlite() {
    local path="$1"
    sqlite3 "$path" '.dump' 2>/dev/null
}

# ============================================
# Network Capture
# ============================================
extract_pcap() {
    local path="$1"
    tcpdump -r "$path" -nn -A 2>/dev/null
}

# ============================================
# Thumbs.db
# ============================================
extract_thumbsdb() {
    local path="$1"
    local output_dir="$2"
    vinetto "$path" -o "$output_dir" 2>/dev/null
}
