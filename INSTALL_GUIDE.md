# Crawl: Установка, проблемы и использование

## Обзор

**Crawl** — платформа для краулинга документов и полнотекстового поиска. Извлекает текст из файлов различных форматов (doc, pdf, xls, exe, images и др.) по сети (SMB, NFS, FTP, HTTP) и индексирует для поиска.

**Применение:** пентест, аудит безопасности, поиск конфиденциальных данных в корпоративных сетях.

**Автор:** s0i37

---

## Оглавление

- [Быстрая установка](#быстрая-установка)
- [Ручная установка на Kali Linux](#ручная-установка-на-kali-linux)
- [Проблемы при установке и их решения](#проблемы-при-установке-и-их-решения)
- [Запуск компонентов](#запуск-компонентов)
- [Использование (Workflow)](#использование-workflow)
- [Многопоточный краулинг](#многопоточный-краулинг)
- [Методы поиска](#методы-поиска)
- [CLI-утилиты](#cli-утилиты)
- [Полезные опции crawl.sh](#полезные-опции-crawlsh)
- [Переменные окружения](#переменные-окружения)
- [Поддерживаемые форматы](#поддерживаемые-форматы)
- [Быстрый старт (cheatsheet)](#быстрый-старт-cheatsheet)

---

## Быстрая установка

Используйте интерактивный установщик:

```bash
cd /opt
sudo git clone https://github.com/s0i37/crawl.git
cd crawl
sudo ./install.sh
```

Установщик предложит выбрать компоненты:
- **Базовые зависимости** — устанавливаются автоматически
- **Email-обработка** — Outlook .msg, .eml
- **OCR** — Tesseract для распознавания текста на изображениях
- **Аудио/Видео** — FFmpeg для медиафайлов
- **Сетевые инструменты** — nmap, smbclient, ldap-utils
- **Дополнительные инструменты** — yq, radare2, evtx, pycdc, vosk
- **OpenSearch + Web GUI** — полнотекстовый поиск с веб-интерфейсом

Установщик автоматически:
- Устанавливает зависимости
- Патчит конфигурации для работы без SSL
- Настраивает права доступа
- Исправляет line endings

---

## Ручная установка на Kali Linux

### Шаг 1: Базовые зависимости

```bash
sudo apt update && sudo apt upgrade -y

# Базовые утилиты
sudo apt install -y wget curl cifs-utils nfs-common rsync file sqlite3 python3 python3-pip xz-utils jq bc parallel

# Обработка документов
sudo apt install -y lynx uchardet catdoc unzip python3-pdfminer poppler-utils p7zip-full liblnk-utils vinetto cabextract rpm2cpio cpio

# Email
sudo apt install -y maildir-utils mpack libemail-outlook-message-perl libemail-sender-perl

# Медиа и OCR
sudo apt install -y graphicsmagick-imagemagick-compat tesseract-ocr tesseract-ocr-eng tesseract-ocr-rus ffmpeg

# Сетевые инструменты
sudo apt install -y ldap-utils bind9-host nmap netcat-openbsd smbclient
```

### Шаг 2: Дополнительные инструменты

```bash
# xq (XML/JSON процессор)
pip3 install yq

# evtx (Windows Event Logs)
wget https://github.com/omerbenamram/evtx/releases/download/v0.9.0/evtx_dump-v0.9.0-x86_64-unknown-linux-gnu -O /tmp/evtx
sudo mv /tmp/evtx /usr/local/bin/evtx
sudo chmod +x /usr/local/bin/evtx

# pycdc (Python bytecode декомпилятор)
cd /tmp
git clone https://github.com/zrax/pycdc
cd pycdc && cmake . && make && sudo make install

# vosk (распознавание речи) — опционально
pip3 install vosk
```

### Шаг 3: Клонирование проекта

```bash
cd /opt
sudo git clone https://github.com/s0i37/crawl.git
sudo chown -R $USER:$USER /opt/crawl
cd /opt/crawl
chmod +x *.sh
chmod +x bin/wget
```

### Шаг 4: Установка OpenSearch и Web GUI (опционально)

```bash
# Node.js и Java
sudo apt install -y nodejs npm openjdk-17-jre

# Python-зависимости
pip3 install opensearch-py colorama

# OpenSearch
cd /tmp
wget https://artifacts.opensearch.org/releases/bundle/opensearch/2.11.0/opensearch-2.11.0-linux-x64.tar.gz
sudo tar xvf opensearch-2.11.0-linux-x64.tar.gz -C /opt/
sudo chown -R $USER:$USER /opt/opensearch-2.11.0

# Web-интерфейс
cd /opt/crawl/www
npm install
sudo npm install -g bower
bower install --allow-root
mv bower_components static
```

---

## Проблемы при установке и их решения

### Проблема 1: OpenSearch не запускается (SSL ошибка)

**Ошибка:**
```
OpenSearchException: plugins.security.ssl.transport.keystore_filepath must be set if transport ssl is requested
```

**Причина:** Security plugin требует SSL-сертификаты.

**Решение:** Отключить security plugin:
```bash
echo "plugins.security.disabled: true" >> /opt/opensearch-2.11.0/config/opensearch.yml
```

---

### Проблема 2: opensearch.py — ошибка API

**Ошибка:**
```
TypeError: IndicesClient.create() takes 1 positional argument but 2 positional arguments were given
```

**Причина:** Изменился API в новой версии opensearch-py.

**Решение:**
```bash
sed -i 's/client.indices.create(index, body=SETTINGS)/client.indices.create(index=index, body=SETTINGS)/' /opt/crawl/opensearch.py
```

---

### Проблема 3: opensearch.py — SSL connection error

**Ошибка:**
```
SSLError: ConnectionError([SSL: RECORD_LAYER_FAILURE])
```

**Причина:** Скрипт пытается подключиться по HTTPS, а OpenSearch работает без SSL.

**Решение:** Изменить настройки подключения в `/opt/crawl/opensearch.py`:
```bash
sed -i 's/use_ssl = True/use_ssl = False/' /opt/crawl/opensearch.py
sed -i 's/http_auth = CREDS,/# http_auth = CREDS,/' /opt/crawl/opensearch.py
sed -i 's/verify_certs = False,/# verify_certs = False,/' /opt/crawl/opensearch.py
sed -i 's/ssl_assert_hostname = False,/# ssl_assert_hostname = False,/' /opt/crawl/opensearch.py
sed -i 's/ssl_show_warn = False/# ssl_show_warn = False/' /opt/crawl/opensearch.py
```

---

### Проблема 4: Node.js Web GUI — SSL error

**Ошибка:**
```
ConnectionError: write EPROTO SSL routines:ssl_get_more_records:packet length too long
```

**Причина:** Web GUI тоже пытается подключиться по HTTPS.

**Решение:** Изменить `/opt/crawl/www/requestHandlers.js`:
```bash
sed -i 's|https://admin:admin@localhost:9200|http://localhost:9200|' /opt/crawl/www/requestHandlers.js
sed -i 's|ssl: {rejectUnauthorized: false}|// ssl: {rejectUnauthorized: false}|' /opt/crawl/www/requestHandlers.js
```

---

### Проблема 5: Web GUI — index not found

**Ошибка:**
```
ResponseError: index_not_found_exception: no such index [default]
```

**Причина:** Индекс не создан или неправильный URL.

**Решение:**
```bash
# Создать индекс
./opensearch.py localhost:9200 -i test -init

# Открывать правильный URL (с именем индекса)
# http://localhost:8080/test/
```

---

### Проблема 6: OpenSearch — недостаточно памяти

**Ошибка:**
```
OpenSearch exited unexpectedly
```

**Решение:** Увеличить лимиты и уменьшить heap:
```bash
# Увеличить лимиты
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf

# Уменьшить heap (если мало RAM)
# Редактировать /opt/opensearch-2.11.0/config/jvm.options:
# -Xms512m
# -Xmx512m
```

---

## Запуск компонентов

### Только CLI (минимум)
```bash
cd /opt/crawl
./crawl.sh  # проверка работы
```

### С OpenSearch и Web GUI

**Терминал 1 — OpenSearch:**
```bash
/opt/opensearch-2.11.0/bin/opensearch
```

**Терминал 2 — Web GUI:**
```bash
cd /opt/crawl/www && node index.js
```

**Терминал 3 — Работа с crawl:**
```bash
cd /opt/crawl
./opensearch.py localhost:9200 -i myindex -init
```

**Браузер:**
```
http://localhost:8080/myindex/
```

---

## Использование (Workflow)

### Схема работы

```
┌─────────────────────────────────────────────────────────────────┐
│                        WORKFLOW CRAWL                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. ПОЛУЧЕНИЕ ДОСТУПА        2. КРАУЛИНГ           3. ПОИСК    │
│  ┌─────────────────┐      ┌─────────────────┐   ┌────────────┐ │
│  │ mount SMB/NFS   │      │  crawl.sh       │   │ grep       │ │
│  │ spider HTTP/FTP │  →   │  crawl_mt.sh    │ → │ search.sh  │ │
│  │ rsync           │      │  (multi-thread) │   │ Web GUI    │ │
│  └─────────────────┘      └─────────────────┘   └────────────┘ │
│           ↓                       ↓                    ↓        │
│     Локальные файлы         index.csv            Результаты    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

### Сценарий 1: SMB-шара (самый частый)

```bash
# 1. Монтирование
mkdir -p smb/192.168.1.100/share
sudo mount.cifs "//192.168.1.100/share" smb/192.168.1.100/share \
    -o ro,user=admin,pass=Password123,dom=CORP

# 2. Краулинг (файлы до 10MB, исключая системные папки)
# Однопоточный:
./crawl.sh smb/192.168.1.100/share -size -10M \
    -not -ipath '*/Windows/*' \
    -not -ipath '*/Program Files/*'

# Многопоточный (8 потоков, быстрее в 4-8 раз):
./crawl_mt.sh smb/192.168.1.100/share 8 -size -10M \
    -not -ipath '*/Windows/*' \
    -not -ipath '*/Program Files/*'

# 3. Поиск
grep -i "password" smb_192.168.1.100_share.csv

# 4. Отмонтирование
sudo umount smb/192.168.1.100/share
```

---

### Сценарий 2: Веб-сайт

```bash
# 1. Скачиваем сайт локально
./spider.sh --limit-size=500k --level=3 http://intranet.corp.local/

# 2. Краулим скачанное
./crawl.sh intranet.corp.local/

# 3. Ищем интересное
grep -i "password\|config" intranet.corp.local.csv
```

---

### Сценарий 3: FTP

```bash
# 1. Скачиваем с FTP
./spider.sh --limit-size=1M ftp://192.168.1.50/

# 2. Краулим
./crawl.sh 192.168.1.50/

# 3. Поиск
grep -i "backup\|dump" 192.168.1.50.csv
```

---

### Сценарий 4: NFS

```bash
# 1. Смотрим доступные шары
showmount -e 192.168.1.200

# 2. Монтируем
mkdir -p nfs/192.168.1.200/data
sudo mount.nfs 192.168.1.200:/data nfs/192.168.1.200/data -o ro,nolock

# 3. Краулим
./crawl.sh nfs/192.168.1.200/data -size -5M

# 4. Поиск
grep -i "id_rsa\|private" nfs_192.168.1.200_data.csv
```

---

### Сценарий 5: Локальная папка

```bash
# Краулим интересные директории
./crawl.sh /home/ -size -10M
./crawl.sh /var/www/ -size -5M

# Объединяем и ищем
cat *.csv > all.csv
grep -i "password\|secret" all.csv
```

---

## Многопоточный краулинг

Для больших объёмов данных используйте `crawl_mt.sh` — многопоточную версию краулера:

```bash
./crawl_mt.sh <folder> [threads] [find options]
```

**Примеры:**

```bash
# 8 потоков, файлы до 10MB
./crawl_mt.sh smb/server/share 8 -size -10M

# 12 потоков, только документы
./crawl_mt.sh folder/ 12 -iname '*.doc' -o -iname '*.pdf'

# С исключением папок через переменную окружения
EXCLUDE_DIRS=Windows,Temp,Cache ./crawl_mt.sh folder/ 4
```

**Особенности crawl_mt.sh:**

| Функция | Описание |
|---------|----------|
| Сессии | Автоматическое возобновление при прерывании |
| Thread-safe | Безопасная запись в CSV из нескольких потоков |
| URL-формирование | SMB-пути преобразуются в `file://server/share` |
| Гибкое исключение | Переменная `EXCLUDE_DIRS` для пропуска папок |

**Формат CSV (8 столбцов):**
```
timestamp,fullpath,relpath,server,share,ext,type,content
```

---

## Методы поиска

### Метод 1: grep (быстро, без подготовки)

```bash
# Пароли
grep -ia -o -P ".{0,50}password.{0,50}" *.csv | grep -i --color password

# API ключи
grep -ia "api.key\|apikey\|token\|bearer" *.csv

# AWS
grep -ia "AKIA\|aws_secret" *.csv

# SSH ключи
grep -ia "BEGIN RSA\|BEGIN PRIVATE\|id_rsa" *.csv

# Подключения к БД
grep -ia "connectionstring\|jdbc\|mysql://" *.csv

# Внутренние сервисы
grep -ia "jenkins\|gitlab\|jira\|confluence" *.csv
```

---

### Метод 2: SQLite + FTS5 (большие объёмы)

SQLite с FTS5 обеспечивает быстрый полнотекстовый поиск с ранжированием BM25.

```bash
# Импорт (создаёт FTS5 базу)
./import.sh *.csv

# Поиск по типу файла
./search.sh -t word index.db 'password'
./search.sh -t excel index.db 'credentials'
./search.sh -t pdf index.db 'confidential'

# Поиск по URL-префиксу
./search.sh -u 'backup' index.db 'admin'
./search.sh -u 'config' index.db 'secret'

# С лимитом и смещением
./search.sh -c 20 -o 0 index.db 'password'
```

**Опции search.sh:**
| Опция | Описание |
|-------|----------|
| `-u` | Фильтр по URL-префиксу |
| `-t` | Фильтр по типу файла |
| `-e` | Фильтр по расширению |
| `-c` | Лимит результатов (default: 10) |
| `-o` | Смещение (пагинация) |

**FTS5 синтаксис запросов:**
| Синтаксис | Описание |
|-----------|----------|
| `word1 word2` | Документы с обоими словами |
| `word1 OR word2` | Документы с любым словом |
| `"exact phrase"` | Точная фраза |
| `word*` | Префиксный поиск |
| `NOT word` | Исключить слово |

---

### Метод 3: Web GUI (enterprise)

```bash
# Создание индекса
./opensearch.py localhost:9200 -i pentest -init

# Импорт данных
./opensearch.py localhost:9200 -i pentest -import data.csv

# Открыть браузер
firefox http://localhost:8080/pentest/
```

**Возможности Web GUI:**
- Полнотекстовый поиск с fuzzy matching
- Автодополнение
- Поиск по изображениям (`?images=1`)
- JSON API (`?json`)
- Пагинация

---

## CLI-утилиты

### stat.sh — статистика по базе

Показывает количество файлов по типам:

```bash
./stat.sh index.db

# Пример вывода:
# index.db
# word      1234
# excel     567
# pdf       890
# text      2345
# image     123
```

### cache.sh — просмотр кэшированного контента

Показывает извлечённый текст для файлов по пути:

```bash
./cache.sh 'documents/report' index.db

# Выводит:
# /path/to/documents/report.docx [word]
# <содержимое файла>
```

---

## Полезные опции crawl.sh

| Опция | Описание | Пример |
|-------|----------|--------|
| `-size -10M` | Файлы до 10MB | `./crawl.sh folder/ -size -10M` |
| `-size +1M` | Файлы больше 1MB | `./crawl.sh folder/ -size +1M` |
| `-iname '*.doc'` | По расширению | `./crawl.sh folder/ -iname '*.pdf'` |
| `-not -ipath` | Исключить путь | `-not -ipath '*/Windows/*'` |
| `-mtime -7` | За последние N дней | `./crawl.sh folder/ -mtime -7` |
| `-newermt` | Новее даты | `-newermt '2024-01-01'` |
| `-maxdepth` | Глубина вложенности | `-maxdepth 3` |

**Комбинированный пример:**
```bash
./crawl.sh target/ -size -10M \
    -not -ipath '*/Windows/*' \
    -not -ipath '*/Program Files/*' \
    -not -iname '*.dll' \
    -not -iname '*.exe' \
    -mtime -30
```

---

## Переменные окружения

Для `crawl_mt.sh` доступны переменные для управления OCR:

| Переменная | Описание | Default |
|------------|----------|---------|
| `OCR_MIN_TEXT` | Мин. символов из pdf2txt до пропуска OCR | 100 |
| `OCR_MAX_IMAGES` | Макс. картинок для OCR (0 = без лимита) | 0 |
| `OCR_DISABLED` | Полностью отключить OCR (1 = отключить) | 0 |
| `IMAGES` | Папка для сохранения миниатюр | - |
| `EXCLUDE_DIRS` | Исключить папки (через запятую) | - |

**Примеры:**

```bash
# Отключить OCR для ускорения
OCR_DISABLED=1 ./crawl_mt.sh folder/ 8

# Ограничить OCR до 5 картинок на документ
OCR_MAX_IMAGES=5 ./crawl_mt.sh folder/ 4

# Исключить системные папки
EXCLUDE_DIRS=Windows,Temp,Cache,node_modules ./crawl_mt.sh folder/ 8

# Сохранять миниатюры изображений
IMAGES=/opt/crawl/www/static/images ./crawl_mt.sh folder/ 4
```

---

## Поддерживаемые форматы

| Категория | Форматы | Инструмент |
|-----------|---------|------------|
| Документы | doc, docx, xls, xlsx, pptx, pdf, odt, vsdx | catdoc, unzip, pdf2txt |
| Текст | txt, xml, html, json, ini, csv | cat, lynx |
| Архивы | 7z, zip, rar, tar, gz, cab, rpm, deb | 7z, cabextract, dpkg |
| Изображения | jpg, png, gif, bmp | tesseract (OCR) |
| Аудио | wav, mp3, flac | vosk (speech-to-text) |
| Видео | mkv, mp4, avi | ffmpeg |
| Бинарники | exe, dll, elf, so | rabin2 |
| Email | eml, msg | mu, msgconvert |
| Другое | lnk, thumbs.db, pcap, evtx, sqlite, pyc | lnkinfo, vinetto, tcpdump, evtx, pycdc |

---

## Быстрый старт (cheatsheet)

```bash
# === УСТАНОВКА ===

cd /opt
sudo git clone https://github.com/s0i37/crawl.git
cd crawl
sudo ./install.sh


# === МИНИМАЛЬНЫЙ WORKFLOW ===

# 1. Краулинг папки (однопоточный)
./crawl.sh target_folder/ -size -10M

# 1. Краулинг папки (многопоточный, рекомендуется)
./crawl_mt.sh target_folder/ 8 -size -10M

# 2. Быстрый поиск паролей
grep -i "password\|secret\|token\|api.key" *.csv

# 3. Поиск с контекстом
grep -ia -o -P ".{0,50}password.{0,50}" *.csv


# === РАСШИРЕННЫЙ WORKFLOW ===

# 1. Импорт в SQLite (FTS5)
./import.sh *.csv

# 2. Поиск по базе
./search.sh index.db 'password'
./search.sh -t pdf index.db 'confidential'
./search.sh index.db 'admin OR root'

# 3. Статистика
./stat.sh index.db

# 4. Просмотр кэша
./cache.sh 'documents/report' index.db


# === WEB GUI ===

# 1. Запустить OpenSearch (отдельный терминал)
/opt/opensearch-2.11.0/bin/opensearch

# 2. Запустить Web GUI (отдельный терминал)
cd /opt/crawl/www && node index.js

# 3. Создать индекс и импортировать
./opensearch.py localhost:9200 -i test -init
./opensearch.py localhost:9200 -i test -import data.csv

# 4. Открыть браузер
# http://localhost:8080/test/
```

---

## Типичные поисковые запросы для пентеста

```bash
# Учётные данные
grep -i "password\|passwd\|pwd\|credential\|login" *.csv

# Конфигурации
grep -i "connectionstring\|jdbc\|mysql\|postgres\|mongodb\|redis" *.csv

# API и токены
grep -i "api.key\|apikey\|token\|bearer\|authorization" *.csv

# Облачные сервисы
grep -i "AKIA\|aws_access\|aws_secret\|azure\|gcp" *.csv

# SSH и сертификаты
grep -i "BEGIN RSA\|BEGIN PRIVATE\|BEGIN CERTIFICATE\|id_rsa" *.csv

# Внутренние сервисы
grep -i "jenkins\|gitlab\|jira\|confluence\|grafana\|kibana" *.csv

# Бэкапы и дампы
grep -i "backup\|dump\|export\|\.sql\|\.bak" *.csv
```

---

## Ссылки

- **Репозиторий:** https://github.com/s0i37/crawl
- **OpenSearch:** https://opensearch.org/
- **Radare2:** https://rada.re/

---

*Документ обновлён: январь 2026*
