#!/bin/bash

# Crawl Installation Script for Kali Linux / Debian
# Usage: sudo ./install.sh

set -e

RED=$'\x1b[31m'
GREEN=$'\x1b[32m'
YELLOW=$'\x1b[33m'
CYAN=$'\x1b[36m'
RESET=$'\x1b[39m'

echo "${GREEN}========================================${RESET}"
echo "${GREEN}  Crawl Installation Script${RESET}"
echo "${GREEN}========================================${RESET}"
echo ""

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "${RED}[!] Please run as root: sudo ./install.sh${RESET}"
    exit 1
fi

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

echo "[*] Installation directory: $INSTALL_DIR"
echo "[*] User: $REAL_USER"
echo ""

# Функция для вопросов
ask() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    if [ "$default" = "y" ]; then
        read -p "${CYAN}$prompt [Y/n]: ${RESET}" answer
        answer=${answer:-y}
    else
        read -p "${CYAN}$prompt [y/N]: ${RESET}" answer
        answer=${answer:-n}
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

# =============================================================================
# Шаг 1: Базовые зависимости (обязательно)
# =============================================================================
echo "${YELLOW}[1/9] Installing base dependencies (required)...${RESET}"

apt-get update -qq

apt-get install -y -qq \
    wget curl cifs-utils nfs-common rsync file sqlite3 \
    python3 python3-pip xz-utils jq bc \
    parallel \
    2>/dev/null

echo "${GREEN}[+] Base dependencies installed${RESET}"
echo ""

# =============================================================================
# Шаг 2: Обработка документов (обязательно)
# =============================================================================
echo "${YELLOW}[2/9] Installing document processing tools (required)...${RESET}"

apt-get install -y -qq \
    lynx uchardet catdoc unzip \
    python3-pdfminer poppler-utils \
    p7zip-full liblnk-utils cabextract \
    rpm2cpio cpio \
    2>/dev/null

# vinetto (thumbs.db)
apt-get install -y -qq vinetto 2>/dev/null || true

echo "${GREEN}[+] Document tools installed${RESET}"
echo ""

# =============================================================================
# Шаг 3: Email обработка
# =============================================================================
if ask "Install email processing tools (Outlook .msg, .eml)?"; then
    echo "${YELLOW}[3/9] Installing email processing tools...${RESET}"

    apt-get install -y -qq \
        maildir-utils mpack \
        libemail-outlook-message-perl libemail-sender-perl \
        2>/dev/null || true

    echo "${GREEN}[+] Email tools installed${RESET}"
else
    echo "${YELLOW}[3/9] Skipping email tools${RESET}"
fi
echo ""

# =============================================================================
# Шаг 4: OCR (Tesseract)
# =============================================================================
if ask "Install OCR tools (Tesseract for image text recognition)?"; then
    echo "${YELLOW}[4/9] Installing OCR tools...${RESET}"

    apt-get install -y -qq \
        graphicsmagick-imagemagick-compat imagemagick \
        tesseract-ocr tesseract-ocr-eng tesseract-ocr-rus \
        2>/dev/null

    # Дополнительные языки
    if ask "Install additional OCR languages (Ukrainian, German, French, Chinese)?" "n"; then
        apt-get install -y -qq \
            tesseract-ocr-ukr tesseract-ocr-deu \
            tesseract-ocr-fra tesseract-ocr-chi-sim \
            2>/dev/null || true
        echo "${GREEN}[+] Additional OCR languages installed${RESET}"
    fi

    echo "${GREEN}[+] OCR tools installed${RESET}"
else
    echo "${YELLOW}[4/9] Skipping OCR tools${RESET}"
fi
echo ""

# =============================================================================
# Шаг 5: Аудио/Видео (FFmpeg)
# =============================================================================
if ask "Install audio/video processing tools (FFmpeg)?"; then
    echo "${YELLOW}[5/9] Installing audio/video tools...${RESET}"

    apt-get install -y -qq ffmpeg 2>/dev/null

    echo "${GREEN}[+] Audio/video tools installed${RESET}"
else
    echo "${YELLOW}[5/9] Skipping audio/video tools${RESET}"
fi
echo ""

# =============================================================================
# Шаг 6: Сетевые инструменты
# =============================================================================
if ask "Install network tools (nmap, smbclient, ldap-utils)?"; then
    echo "${YELLOW}[6/9] Installing network tools...${RESET}"

    apt-get install -y -qq \
        ldap-utils bind9-host nmap \
        netcat-openbsd smbclient \
        2>/dev/null || true

    echo "${GREEN}[+] Network tools installed${RESET}"
else
    echo "${YELLOW}[6/9] Skipping network tools${RESET}"
fi
echo ""

# =============================================================================
# Шаг 7: Дополнительные инструменты
# =============================================================================
echo "${YELLOW}[7/9] Additional tools...${RESET}"

# yq/xq (XML/JSON processor)
if ask "Install yq/xq (XML/JSON processor for Visio files)?"; then
    pip3 install -q yq 2>/dev/null || true
    echo "${GREEN}[+] yq/xq installed${RESET}"
fi

# radare2
if ask "Install radare2 (binary analysis, string extraction from EXE/DLL)?"; then
    if ! command -v rabin2 &>/dev/null; then
        apt-get install -y -qq radare2 2>/dev/null || true
    fi
    echo "${GREEN}[+] radare2 installed${RESET}"
fi

# evtx (Windows Event Logs)
if ask "Install evtx (Windows Event Log parser)?"; then
    if ! command -v evtx &>/dev/null; then
        echo "  [*] Downloading evtx..."
        EVTX_URL="https://github.com/omerbenamram/evtx/releases/download/v0.9.0/evtx_dump-v0.9.0-x86_64-unknown-linux-gnu"
        wget -q "$EVTX_URL" -O /tmp/evtx 2>/dev/null && \
            mv /tmp/evtx /usr/local/bin/evtx && \
            chmod +x /usr/local/bin/evtx && \
            echo "${GREEN}[+] evtx installed${RESET}" || \
            echo "${RED}[!] evtx installation failed${RESET}"
    else
        echo "${GREEN}[+] evtx already installed${RESET}"
    fi
fi

# pycdc (Python bytecode decompiler)
if ask "Install pycdc (Python bytecode decompiler)?"; then
    if ! command -v pycdc &>/dev/null; then
        echo "  [*] Building pycdc from source..."
        apt-get install -y -qq cmake g++ git 2>/dev/null
        if [ -d /tmp/pycdc ]; then rm -rf /tmp/pycdc; fi
        git clone -q https://github.com/zrax/pycdc /tmp/pycdc 2>/dev/null && \
            cd /tmp/pycdc && \
            cmake . -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 && \
            make -j$(nproc) >/dev/null 2>&1 && \
            make install >/dev/null 2>&1 && \
            cd - >/dev/null && \
            rm -rf /tmp/pycdc && \
            echo "${GREEN}[+] pycdc installed${RESET}" || \
            echo "${RED}[!] pycdc installation failed${RESET}"
    else
        echo "${GREEN}[+] pycdc already installed${RESET}"
    fi
fi

# vosk (speech recognition)
if ask "Install vosk (speech-to-text for audio files)? [~1GB download]" "n"; then
    echo "  [*] Installing vosk..."
    pip3 install -q vosk 2>/dev/null && \
        echo "${GREEN}[+] vosk installed${RESET}" || \
        echo "${RED}[!] vosk installation failed${RESET}"

    echo "  [*] Note: vosk models will be downloaded on first use"
fi

echo ""

# =============================================================================
# Шаг 8: OpenSearch + Web GUI
# =============================================================================
if ask "Install OpenSearch + Web GUI (full-text search with web interface)?" "n"; then
    echo "${YELLOW}[8/9] Installing OpenSearch + Web GUI...${RESET}"

    # Node.js
    echo "  [*] Installing Node.js..."
    apt-get install -y -qq nodejs npm 2>/dev/null

    # Java
    echo "  [*] Installing Java..."
    apt-get install -y -qq openjdk-17-jre 2>/dev/null

    # Python dependencies
    echo "  [*] Installing Python dependencies..."
    pip3 install -q opensearch-py colorama 2>/dev/null

    # OpenSearch
    if [ ! -d "/opt/opensearch-2.11.0" ]; then
        echo "  [*] Downloading OpenSearch 2.11.0 (~500MB)..."
        cd /tmp
        wget -q --show-progress "https://artifacts.opensearch.org/releases/bundle/opensearch/2.11.0/opensearch-2.11.0-linux-x64.tar.gz"
        echo "  [*] Extracting..."
        tar xf opensearch-2.11.0-linux-x64.tar.gz -C /opt/
        chown -R "$REAL_USER:$REAL_USER" /opt/opensearch-2.11.0
        rm opensearch-2.11.0-linux-x64.tar.gz

        # Disable security plugin
        echo "plugins.security.disabled: true" >> /opt/opensearch-2.11.0/config/opensearch.yml

        # Fix memory limits
        echo "vm.max_map_count=262144" >> /etc/sysctl.conf
        sysctl -w vm.max_map_count=262144 2>/dev/null || true

        echo "${GREEN}[+] OpenSearch installed to /opt/opensearch-2.11.0${RESET}"
    else
        echo "${GREEN}[+] OpenSearch already installed${RESET}"
    fi

    # Web GUI dependencies
    echo "  [*] Installing Web GUI dependencies..."
    cd "$INSTALL_DIR/www"
    sudo -u "$REAL_USER" npm install --silent 2>/dev/null

    if ! command -v bower &>/dev/null; then
        npm install -g bower --silent 2>/dev/null
    fi

    sudo -u "$REAL_USER" bower install --allow-root --silent 2>/dev/null || true

    if [ -d "bower_components" ] && [ ! -d "static" ]; then
        mv bower_components static
    fi

    cd "$INSTALL_DIR"

    # Patch opensearch.py for HTTP (no SSL)
    sed -i 's/use_ssl = True/use_ssl = False/' "$INSTALL_DIR/opensearch.py" 2>/dev/null || true
    sed -i 's/http_auth = CREDS,/# http_auth = CREDS,/' "$INSTALL_DIR/opensearch.py" 2>/dev/null || true
    sed -i 's/verify_certs = False,/# verify_certs = False,/' "$INSTALL_DIR/opensearch.py" 2>/dev/null || true
    sed -i 's/ssl_assert_hostname = False,/# ssl_assert_hostname = False,/' "$INSTALL_DIR/opensearch.py" 2>/dev/null || true
    sed -i 's/ssl_show_warn = False/# ssl_show_warn = False/' "$INSTALL_DIR/opensearch.py" 2>/dev/null || true

    # Patch requestHandlers.js for HTTP
    sed -i 's|https://admin:admin@localhost:9200|http://localhost:9200|' "$INSTALL_DIR/www/requestHandlers.js" 2>/dev/null || true

    # Fix API compatibility
    sed -i 's/client.indices.create(index, body=SETTINGS)/client.indices.create(index=index, body=SETTINGS)/' "$INSTALL_DIR/opensearch.py" 2>/dev/null || true

    echo "${GREEN}[+] OpenSearch + Web GUI installed${RESET}"
    echo ""
    echo "  To start OpenSearch:"
    echo "    ${CYAN}/opt/opensearch-2.11.0/bin/opensearch${RESET}"
    echo ""
    echo "  To start Web GUI:"
    echo "    ${CYAN}cd $INSTALL_DIR/www && node index.js${RESET}"
    echo ""
    echo "  Then open: ${CYAN}http://localhost:8080/<index>/${RESET}"
else
    echo "${YELLOW}[8/9] Skipping OpenSearch + Web GUI${RESET}"
fi
echo ""

# =============================================================================
# Шаг 9: Настройка проекта
# =============================================================================
echo "${YELLOW}[9/9] Configuring project...${RESET}"

cd "$INSTALL_DIR"

# Права на скрипты
chmod +x *.sh 2>/dev/null || true
chmod +x bin/wget 2>/dev/null || true
chmod +x cron/*.sh 2>/dev/null || true

# Исправление Windows line endings
for script in *.sh cron/*.sh; do
    if [ -f "$script" ]; then
        sed -i 's/\r$//' "$script" 2>/dev/null || true
    fi
done

# Владелец — реальный пользователь
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

echo "${GREEN}[+] Project configured${RESET}"

# =============================================================================
# Готово
# =============================================================================
echo ""
echo "${GREEN}========================================${RESET}"
echo "${GREEN}  Installation Complete!${RESET}"
echo "${GREEN}========================================${RESET}"
echo ""
echo "Usage:"
echo "  ${CYAN}./crawl.sh folder/ -size -10M${RESET}                    # Single-threaded"
echo "  ${CYAN}./crawl_mt.sh folder/ 8 -size -10M${RESET}               # Multi-threaded"
echo ""
echo "Mount SMB share:"
echo "  ${CYAN}mkdir -p smb/server/share${RESET}"
echo "  ${CYAN}sudo mount.cifs //server/share smb/server/share -o ro,credentials=~/.smbcredentials${RESET}"
echo ""
echo "Quick search:"
echo "  ${CYAN}grep -i 'password' *.csv${RESET}"
echo "  ${CYAN}./search.sh index.db 'secret'${RESET}"
echo ""
echo "${GREEN}Happy hunting!${RESET}"
