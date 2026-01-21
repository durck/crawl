#!/usr/bin/env python3
"""
OpenSearch management tool for Crawl
Handles index creation, CSV import, search, and document caching

Usage:
    ./opensearch.py localhost:9200 -i index_name -init
    ./opensearch.py localhost:9200 -i index_name -import data.csv
    ./opensearch.py localhost:9200 -i index_name -query "search terms"
"""

import csv
import json
import os
import sys
import argparse
import logging
from hashlib import md5
from datetime import datetime
from pathlib import Path
from contextlib import contextmanager

try:
    from opensearchpy import OpenSearch
    from opensearchpy.exceptions import NotFoundError, RequestError
except ImportError:
    print("Error: opensearch-py not installed. Run: pip install opensearch-py")
    sys.exit(1)

try:
    from colorama import Fore, Style, init as colorama_init
    colorama_init()
except ImportError:
    # Fallback if colorama not available
    class Fore:
        RED = GREEN = YELLOW = CYAN = LIGHTBLACK_EX = RESET = ""
    class Style:
        RESET_ALL = ""

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


def get_credentials():
    """Load credentials from environment or config file."""
    # Try environment variables first
    user = os.environ.get('OPENSEARCH_USER', '')
    password = os.environ.get('OPENSEARCH_PASS', '')

    if user and password:
        return (user, password)

    # Try config files
    config_paths = [
        Path.home() / '.crawl-credentials.conf',
        Path('/etc/crawl/credentials.conf'),
        Path(__file__).parent / 'config' / 'credentials.conf',
    ]

    for config_path in config_paths:
        if config_path.exists():
            try:
                with open(config_path) as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith('OPENSEARCH_USER='):
                            user = line.split('=', 1)[1].strip('"\'')
                        elif line.startswith('OPENSEARCH_PASS='):
                            password = line.split('=', 1)[1].strip('"\'')
                if user and password:
                    return (user, password)
            except Exception as e:
                logger.warning(f"Could not read {config_path}: {e}")

    # Default fallback (should be changed in production!)
    logger.warning("Using default credentials. Set OPENSEARCH_USER/OPENSEARCH_PASS environment variables.")
    return ('admin', 'admin')


def get_ssl_settings():
    """Get SSL settings from environment."""
    verify_certs = os.environ.get('OPENSEARCH_VERIFY_CERTS', 'false').lower() == 'true'
    use_ssl = os.environ.get('OPENSEARCH_USE_SSL', 'true').lower() == 'true'
    return {
        'use_ssl': use_ssl,
        'verify_certs': verify_certs,
        'ssl_assert_hostname': False,
        'ssl_show_warn': False,
    }


@contextmanager
def get_client(host: str, port: int):
    """Create OpenSearch client with proper resource management."""
    creds = get_credentials()
    ssl_settings = get_ssl_settings()

    client = OpenSearch(
        hosts=[{'host': host, 'port': port}],
        http_compress=True,
        http_auth=creds,
        **ssl_settings
    )

    try:
        yield client
    finally:
        client.close()


def list_indexes(client):
    """List all indexes with document counts."""
    try:
        indexes = client.indices.get("*")
        for index_name in sorted(indexes.keys()):
            if not index_name.startswith('.'):  # Skip system indexes
                count = client.cat.count(index_name, format='json')[0]['count']
                print(f"{index_name}: {count} documents")
    except Exception as e:
        logger.error(f"Failed to list indexes: {e}")


def get_index_info(client, index: str):
    """Get detailed index information."""
    try:
        settings = client.indices.get_settings(index=index)
        mappings = client.indices.get_mapping(index=index)
        print(json.dumps({
            'settings': settings,
            'mappings': mappings
        }, indent=2))
    except NotFoundError:
        logger.error(f"Index not found: {index}")
    except Exception as e:
        logger.error(f"Failed to get index info: {e}")


def create_index(client, index: str):
    """Create index with optimized settings for document search."""
    settings = {
        "mappings": {
            "properties": {
                "timestamp": {
                    "type": "date",
                    "format": "yyyy-MM-dd HH:mm:ss||epoch_second"
                },
                "inurl": {
                    "type": "text",
                    "analyzer": "path_analyzer",
                    "fields": {"keyword": {"type": "keyword"}}
                },
                "relpath": {"type": "keyword"},
                "server": {"type": "keyword"},
                "share": {"type": "keyword"},
                "site": {"type": "keyword"},
                "ext": {"type": "keyword"},
                "intitle": {"type": "text", "analyzer": "multilang"},
                "intext": {"type": "text", "analyzer": "multilang"},
                "filetype": {"type": "keyword"}
            }
        },
        "settings": {
            "index": {
                "number_of_shards": int(os.environ.get('OPENSEARCH_SHARDS', 1)),
                "number_of_replicas": int(os.environ.get('OPENSEARCH_REPLICAS', 0)),
                "refresh_interval": "30s"  # Optimize for bulk imports
            },
            "analysis": {
                "analyzer": {
                    "default": {
                        "type": "custom",
                        "tokenizer": "standard",
                        "filter": ["lowercase", "multilang_stop", "multilang_stemmer"]
                    },
                    "multilang": {
                        "type": "custom",
                        "tokenizer": "standard",
                        "filter": ["lowercase", "multilang_stop", "multilang_stemmer"]
                    },
                    "path_analyzer": {
                        "type": "custom",
                        "tokenizer": "path_tokenizer",
                        "filter": ["lowercase"]
                    },
                    "autocomplete": {
                        "type": "custom",
                        "tokenizer": "standard",
                        "filter": ["lowercase", "autocomplete_filter"]
                    }
                },
                "tokenizer": {
                    "path_tokenizer": {
                        "type": "path_hierarchy",
                        "delimiter": "/"
                    }
                },
                "filter": {
                    "multilang_stop": {
                        "type": "stop",
                        "stopwords": "_russian_"
                    },
                    "multilang_stemmer": {
                        "type": "stemmer",
                        "language": "russian"
                    },
                    "autocomplete_filter": {
                        "type": "edge_ngram",
                        "min_gram": 2,
                        "max_gram": 20
                    }
                }
            }
        }
    }

    try:
        response = client.indices.create(index, body=settings)
        logger.info(f"Index created: {index}")
        print(json.dumps(response, indent=2))
    except RequestError as e:
        if 'resource_already_exists_exception' in str(e):
            logger.warning(f"Index already exists: {index}")
        else:
            logger.error(f"Failed to create index: {e}")
            raise


def import_csv(client, index: str, source: str, batch_size: int = 500):
    """Import CSV data with bulk operations."""
    csv.field_size_limit(2**31 - 1)  # Handle large fields

    site = Path(source).stem

    try:
        with open(source, errors='surrogateescape', newline='') as f:
            reader = csv.reader(f, delimiter=',', quotechar='"')

            batch = []
            total = 0
            errors = 0

            for row in reader:
                try:
                    # Handle both old and new CSV formats
                    if len(row) >= 8:
                        timestamp, fullpath, relpath, server, share, ext, filetype, content = row[:8]
                    elif len(row) >= 5:
                        # Old format fallback
                        timestamp, fullpath, ext, filetype, content = row[:5]
                        relpath, server, share = fullpath, "", ""
                    else:
                        logger.warning(f"Skipping malformed row: {row[:50]}...")
                        errors += 1
                        continue

                    # Generate document ID from path
                    doc_id = md5(fullpath.encode()).hexdigest()

                    # Bulk format: action + document
                    batch.append({"index": {"_index": index, "_id": doc_id}})
                    batch.append({
                        "timestamp": datetime.fromtimestamp(int(timestamp)).strftime('%Y-%m-%d %H:%M:%S'),
                        "inurl": fullpath,
                        "relpath": relpath,
                        "server": server,
                        "share": share,
                        "site": site,
                        "ext": ext,
                        "intitle": "",
                        "intext": content,
                        "filetype": filetype
                    })

                    # Flush batch when full
                    if len(batch) >= batch_size * 2:
                        response = client.bulk(body=batch, refresh=False)
                        if response.get('errors'):
                            batch_errors = sum(1 for item in response['items'] if item['index'].get('error'))
                            errors += batch_errors
                        total += len(batch) // 2
                        print(f"\r[*] Imported {total} documents, {errors} errors", end='', flush=True)
                        batch = []

                except ValueError as e:
                    errors += 1
                    logger.debug(f"Value error: {e}")
                except Exception as e:
                    errors += 1
                    logger.warning(f"Error processing row: {e}")

            # Flush remaining documents
            if batch:
                response = client.bulk(body=batch, refresh=False)
                if response.get('errors'):
                    batch_errors = sum(1 for item in response['items'] if item['index'].get('error'))
                    errors += batch_errors
                total += len(batch) // 2

            # Final refresh
            client.indices.refresh(index=index)

            print(f"\n[+] Done: {total} documents imported, {errors} errors")

    except FileNotFoundError:
        logger.error(f"File not found: {source}")
    except Exception as e:
        logger.error(f"Import failed: {e}")
        raise


def delete_csv(client, index: str, source: str, batch_size: int = 500):
    """Delete documents listed in CSV file."""
    csv.field_size_limit(2**31 - 1)

    try:
        with open(source, errors='surrogateescape', newline='') as f:
            reader = csv.reader(f, delimiter=',', quotechar='"')

            batch = []
            total = 0
            errors = 0

            for row in reader:
                try:
                    if len(row) >= 8:
                        fullpath = row[1]
                    elif len(row) >= 5:
                        fullpath = row[1]
                    else:
                        continue

                    doc_id = md5(fullpath.encode()).hexdigest()
                    batch.append({"delete": {"_index": index, "_id": doc_id}})

                    if len(batch) >= batch_size:
                        response = client.bulk(body=batch, refresh=False)
                        if response.get('errors'):
                            batch_errors = sum(1 for item in response['items'] if item['delete'].get('error'))
                            errors += batch_errors
                        total += len(batch)
                        print(f"\r[*] Deleted {total} documents, {errors} errors", end='', flush=True)
                        batch = []

                except Exception as e:
                    errors += 1

            if batch:
                response = client.bulk(body=batch, refresh=False)
                if response.get('errors'):
                    batch_errors = sum(1 for item in response['items'] if item['delete'].get('error'))
                    errors += batch_errors
                total += len(batch)

            client.indices.refresh(index=index)
            print(f"\n[+] Done: {total} documents deleted, {errors} errors")

    except FileNotFoundError:
        logger.error(f"File not found: {source}")


def search(client, index: str, query: str, count: int = 10, offset: int = 0):
    """Search with highlighting and relevance scoring."""
    # Basic query sanitization
    sanitized_query = query.replace('<', '').replace('>', '').replace(';', '')

    search_body = {
        "size": count,
        "from": offset,
        "query": {
            "query_string": {
                "query": sanitized_query,
                "fields": ["inurl^100", "intitle^50", "intext^5"],
                "default_operator": "AND",
                "fuzziness": "AUTO",
                "analyzer": "default"
            }
        },
        "highlight": {
            "order": "score",
            "fields": {
                "*": {
                    "pre_tags": [Fore.RED],
                    "post_tags": [Fore.RESET],
                    "fragment_size": 50,
                    "number_of_fragments": 3
                }
            }
        }
    }

    try:
        response = client.search(index=index, body=search_body)

        total = response['hits']['total']['value']
        print(f"{Fore.CYAN}Found {total} results{Fore.RESET}\n")

        for hit in response['hits']['hits']:
            src = hit['_source']
            highlight = hit.get('highlight', {})

            uri = highlight.get('inurl', [src['inurl']])[0]
            server = src.get('server', '')
            share = src.get('share', '')
            location = f" [{server}/{share}]" if server else ""

            print(f"{Fore.GREEN}{uri}{Fore.CYAN}{location} {Fore.LIGHTBLACK_EX}{hit['_id']}{Fore.RESET}")

            if 'intext' in highlight:
                print(" ... ".join(highlight['intext']))

            print()

    except NotFoundError:
        logger.error(f"Index not found: {index}")
    except Exception as e:
        logger.error(f"Search failed: {e}")


def get_cache(client, index: str, doc_id: str):
    """Retrieve cached document content."""
    try:
        result = client.get(index=index, id=doc_id)
        print(result["_source"]["intext"])
    except NotFoundError:
        logger.error(f"Document not found: {doc_id}")
    except Exception as e:
        logger.error(f"Cache retrieval failed: {e}")


def drop_index(client, index: str):
    """Delete an index."""
    try:
        response = client.indices.delete(index=index)
        logger.info(f"Index deleted: {index}")
        print(json.dumps(response, indent=2))
    except NotFoundError:
        logger.error(f"Index not found: {index}")
    except Exception as e:
        logger.error(f"Failed to delete index: {e}")


def copy_index(client, src_index: str, dst_index: str):
    """Copy index to new name."""
    try:
        response = client.reindex(body={
            "source": {"index": src_index},
            "dest": {"index": dst_index}
        })
        logger.info(f"Copied {src_index} to {dst_index}")
        print(json.dumps(response, indent=2))
    except Exception as e:
        logger.error(f"Failed to copy index: {e}")


def main():
    parser = argparse.ArgumentParser(
        description='OpenSearch management tool for Crawl',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s localhost:9200                           List all indexes
  %(prog)s localhost:9200 -i myindex -init          Create new index
  %(prog)s localhost:9200 -i myindex -import data.csv  Import CSV
  %(prog)s localhost:9200 -i myindex -query "password"  Search
  %(prog)s localhost:9200 -i myindex -cache abc123  Get document cache

Environment variables:
  OPENSEARCH_USER       Username (default: admin)
  OPENSEARCH_PASS       Password
  OPENSEARCH_USE_SSL    Use SSL (default: true)
  OPENSEARCH_VERIFY_CERTS  Verify certificates (default: false)
"""
    )

    parser.add_argument("opensearch", help="OpenSearch address (host:port)")
    parser.add_argument("-i", "--index", default="", help="Index name")
    parser.add_argument("-o", "--offset", type=int, default=0, help="Results offset")
    parser.add_argument("-c", "--count", type=int, default=10, help="Results count")
    parser.add_argument("-init", action="store_true", help="Create index")
    parser.add_argument("-drop", action="store_true", help="Delete index")
    parser.add_argument("-copy", dest="copy_index", metavar="NEW_INDEX", help="Copy index")
    parser.add_argument("-import", dest="file_import", metavar="CSV", help="Import CSV file")
    parser.add_argument("-delete", dest="file_delete", metavar="CSV", help="Delete documents from CSV")
    parser.add_argument("-query", metavar="QUERY", help="Search query")
    parser.add_argument("-cache", metavar="DOC_ID", help="Get document cache")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Parse host:port
    try:
        host, port = args.opensearch.split(":")
        port = int(port)
    except ValueError:
        logger.error("Invalid address format. Use host:port (e.g., localhost:9200)")
        sys.exit(1)

    # Execute command
    with get_client(host, port) as client:
        if args.init:
            if not args.index:
                logger.error("Index name required (-i)")
                sys.exit(1)
            create_index(client, args.index)

        elif args.drop:
            if not args.index:
                logger.error("Index name required (-i)")
                sys.exit(1)
            drop_index(client, args.index)

        elif args.copy_index:
            if not args.index:
                logger.error("Source index name required (-i)")
                sys.exit(1)
            copy_index(client, args.index, args.copy_index)

        elif args.file_import:
            if not args.index:
                logger.error("Index name required (-i)")
                sys.exit(1)
            import_csv(client, args.index, args.file_import)

        elif args.file_delete:
            if not args.index:
                logger.error("Index name required (-i)")
                sys.exit(1)
            delete_csv(client, args.index, args.file_delete)

        elif args.query:
            if not args.index:
                logger.error("Index name required (-i)")
                sys.exit(1)
            search(client, args.index, args.query, args.count, args.offset)

        elif args.cache:
            if not args.index:
                logger.error("Index name required (-i)")
                sys.exit(1)
            get_cache(client, args.index, args.cache)

        elif args.index:
            get_index_info(client, args.index)

        else:
            list_indexes(client)


if __name__ == "__main__":
    main()
