# Crawl - Document Crawler and Search Platform
# Multi-stage build for smaller final image

FROM debian:12-slim AS base

# Install common dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Builder stage - compile tools
# ============================================
FROM base AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git gcc g++ make cmake xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build pycdc (Python bytecode decompiler)
RUN git clone --depth 1 https://github.com/zrax/pycdc.git && \
    cd pycdc && cmake . && make && make install DESTDIR=/build/out

# Download static tools
RUN wget -q https://github.com/radareorg/radare2/releases/download/5.8.8/radare2-5.8.8-static.tar.xz -O /tmp/radare2.tar.xz && \
    mkdir -p /build/out/opt/radare2 && \
    tar xf /tmp/radare2.tar.xz -C /build/out/opt/radare2 --strip-components=1

RUN wget -q https://github.com/omerbenamram/evtx/releases/download/v0.9.0/evtx_dump-v0.9.0-x86_64-unknown-linux-gnu -O /build/out/usr/local/bin/evtx && \
    chmod +x /build/out/usr/local/bin/evtx

# ============================================
# Runtime stage
# ============================================
FROM base AS runtime

WORKDIR /opt/crawl

# System packages - organized by function
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    file sqlite3 xz-utils jq parallel procps \
    # Network tools
    smbclient ldap-utils bind9-host nmap netcat-openbsd cifs-utils nfs-common rsync \
    # Text extraction
    lynx uchardet catdoc unzip poppler-utils p7zip-full \
    liblnk-utils cabextract rpm2cpio cpio \
    # Email processing
    maildir-utils mpack libemail-outlook-message-perl \
    # Image/OCR
    graphicsmagick-imagemagick-compat \
    tesseract-ocr tesseract-ocr-eng tesseract-ocr-rus \
    # Media processing
    ffmpeg \
    # Python
    python3 python3-pip python3-venv \
    # Node.js
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Copy built tools from builder
COPY --from=builder /build/out/usr/local/bin/pycdc /usr/local/bin/
COPY --from=builder /build/out/opt/radare2/usr/bin/rabin2 /usr/local/bin/
COPY --from=builder /build/out/usr/local/bin/evtx /usr/local/bin/

# Install Python packages in virtual environment
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir \
    opensearch-py colorama vosk xq

ENV PATH="/opt/venv/bin:$PATH"

# Install OpenSearch (optional - can be external)
ARG INSTALL_OPENSEARCH=true
RUN if [ "$INSTALL_OPENSEARCH" = "true" ]; then \
    apt-get update && apt-get install -y --no-install-recommends openjdk-17-jre-headless && \
    wget -q https://artifacts.opensearch.org/releases/bundle/opensearch/2.11.0/opensearch-2.11.0-linux-x64.tar.gz -O /tmp/opensearch.tar.gz && \
    tar xf /tmp/opensearch.tar.gz -C /opt/ && \
    rm /tmp/opensearch.tar.gz && \
    rm -rf /var/lib/apt/lists/* ; \
    fi

# Create non-root user
RUN groupadd -g 1000 crawl && \
    useradd -u 1000 -g crawl -s /bin/bash -m -d /home/crawl crawl

# Copy application files
COPY --chown=crawl:crawl config config/
COPY --chown=crawl:crawl lib lib/
COPY --chown=crawl:crawl www www/
COPY --chown=crawl:crawl bin bin/
COPY --chown=crawl:crawl crawl.sh crawl_mt.sh spider.sh imap.sh import.sh search.sh opensearch.py ./
COPY --chown=crawl:crawl crawlme crawlme/

# Install Node.js dependencies
WORKDIR /opt/crawl/www
RUN npm install --production && \
    npm cache clean --force

WORKDIR /opt/crawl

# Set permissions
RUN chmod +x *.sh *.py && \
    chown -R crawl:crawl /opt/crawl

# Configure locale
RUN apt-get update && apt-get install -y --no-install-recommends locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    sed -i -e 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Environment variables for configuration
ENV OPENSEARCH_HOST=localhost
ENV OPENSEARCH_PORT=9200
ENV OPENSEARCH_USE_SSL=true
ENV OPENSEARCH_VERIFY_CERTS=false
# Credentials should be provided at runtime via secrets/env
# ENV OPENSEARCH_USER=admin
# ENV OPENSEARCH_PASS=

# Healthcheck for OpenSearch
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf -k https://localhost:9200/_cluster/health || exit 1

# Expose ports
# 8080 - Web UI
# 9200 - OpenSearch API
EXPOSE 8080 9200

# Switch to non-root user for runtime
USER crawl

# Default command - can be overridden
CMD ["bash"]

# ============================================
# Labels
# ============================================
LABEL maintainer="Crawl Project"
LABEL description="Document crawler and full-text search platform"
LABEL version="2.0"
