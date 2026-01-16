#!/usr/bin/python3
import csv
import json
from hashlib import md5
from opensearchpy import OpenSearch
from os import path
from datetime import datetime
from colorama import Fore
import argparse


CREDS = ('admin', 'admin')
parser = argparse.ArgumentParser( description='search machine control tool' )
parser.add_argument("opensearch", type=str, default="localhost:9200", help="opensearch address (localhost:9200)")
parser.add_argument("-i", "--index", type=str, metavar="index", default="", help="index where to search")
parser.add_argument("-o", "--offset", type=int, metavar="offset", default=0, help="offset results in query")
parser.add_argument("-c", "--count", type=int, metavar="count", default=10, help="count results in query")
parser.add_argument("-init", action="store_true", help="init index")
parser.add_argument("-drop", action="store_true", help="drop index")
parser.add_argument("-copy", dest="copy_index", metavar="new_index_name", help="copy index")
parser.add_argument("-import", dest="file_import", metavar="input.csv", help="import data")
parser.add_argument("-delete", dest="file_delete", metavar="input.csv", help="delete data")
parser.add_argument("-query", metavar="query", help="search query")
parser.add_argument("-cache", metavar="cache", help="get cache of a document")
args = parser.parse_args()

host,port = args.opensearch.split(":")
client = OpenSearch(
  hosts = [{'host': host, 'port': int(port)}],
  http_compress = True,
  http_auth = CREDS,
  use_ssl = True,
  verify_certs = False,
  ssl_assert_hostname = False,
  ssl_show_warn = False
)

def indexes():
  for index in client.indices.get("*"):
    print(index, client.cat.count(index))

def info(index):
  print(json.dumps(client.indices.get_settings(index=index), indent=4))

def init(index):
  SETTINGS = {
    "mappings": {
      "properties": {
        "timestamp": { "type": "date", "format": "yyyy-MM-dd HH:mm:ss||epoch_second" },
        "inurl": { "type": "text", "analyzer": "path_analyzer", "fields": {"keyword": {"type": "keyword"}} },
        "relpath": { "type": "keyword" },
        "server": { "type": "keyword" },
        "share": { "type": "keyword" },
        "site": { "type": "keyword" },
        "ext": { "type": "keyword" },
        "intitle": { "type": "text", "analyzer": "multilang" },
        "intext": { "type": "text", "analyzer": "multilang" },
        "filetype": { "type": "keyword" }
      }
    },
    "settings": {
      "index": {
        "number_of_shards": 1,
        "number_of_replicas": 0
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

  response = client.indices.create(index, body=SETTINGS)
  print(response)

def add(index, source):
  csv.field_size_limit(2**32)
  reader = csv.reader(open(source, errors="surrogateescape"), delimiter=',', quotechar='"')

  BATCH_SIZE = 500
  batch = []
  total = 0
  errors = 0
  site = path.splitext(path.basename(source))[0]

  for row in reader:
    try:
      # New format: timestamp,fullpath,relpath,server,share,ext,type,content
      # Old format: timestamp,filepath,ext,filetype,content
      if len(row) >= 8:
        timestamp, fullpath, relpath, server, share, ext, filetype, content, *_ = row
      else:
        # Fallback for old CSV format
        timestamp, fullpath, ext, filetype, content, *_ = row
        relpath, server, share = fullpath, "", ""

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

      if len(batch) >= BATCH_SIZE * 2:  # *2 because action+doc pairs
        response = client.bulk(body=batch, refresh=False)
        if response.get('errors'):
          errors += sum(1 for item in response['items'] if item['index'].get('error'))
        total += len(batch) // 2
        print(f"\r[*] Imported {total} documents, {errors} errors", end='', flush=True)
        batch = []

    except Exception as e:
      errors += 1
      print(f"\n[!] {str(e)}")

  # Flush remaining
  if batch:
    response = client.bulk(body=batch, refresh=False)
    if response.get('errors'):
      errors += sum(1 for item in response['items'] if item['index'].get('error'))
    total += len(batch) // 2

  # Final refresh
  client.indices.refresh(index=index)
  print(f"\n[+] Done: {total} documents, {errors} errors")

def query(index, text):
  query = {
    "size": args.count,
    "from": args.offset,
    "query": {
      "query_string": {
        "query": text,
        "fields": ["inurl^100","intitle^50","intext^5"],
        "default_operator": "AND",
        "fuzziness": "AUTO",
        "analyzer": "default"
      }
    },
    "highlight": {
      "order": "score",
      "fields": {
        "*": {
          "pre_tags" : [ Fore.RED ],
          "post_tags" : [ Fore.RESET ],
          "fragment_size": 50,
          "number_of_fragments": 3
        }
      }
    }
  }

  response = client.search(
      index = index,
      body = query
  )
  for result in response['hits']['hits']:
      src = result['_source']
      uri = result['highlight']['inurl'][0] if result['highlight'].get('inurl') else src['inurl']
      server = src.get('server', '')
      share = src.get('share', '')
      location = f"[{server}/{share}]" if server else ""
      print(f"{Fore.GREEN}{uri} {Fore.CYAN}{location} {Fore.LIGHTBLACK_EX}{result['_id']}{Fore.RESET}")
      print(" ... ".join(result['highlight'].get('intext',[])))

def cache(index, _id):
  result = client.get(index=index, id=_id)
  print(result["_source"]["intext"])

def delete(index, source):
  csv.field_size_limit(2**32)
  reader = csv.reader(open(source, errors="surrogateescape"), delimiter=',', quotechar='"')

  BATCH_SIZE = 500
  batch = []
  total = 0
  errors = 0

  for row in reader:
    try:
      # Support both new and old CSV formats
      if len(row) >= 8:
        timestamp, fullpath, relpath, server, share, ext, filetype, content, *_ = row
      else:
        timestamp, fullpath, ext, filetype, content, *_ = row
      doc_id = md5(fullpath.encode()).hexdigest()

      batch.append({"delete": {"_index": index, "_id": doc_id}})

      if len(batch) >= BATCH_SIZE:
        response = client.bulk(body=batch, refresh=False)
        if response.get('errors'):
          errors += sum(1 for item in response['items'] if item['delete'].get('error'))
        total += len(batch)
        print(f"\r[*] Deleted {total} documents, {errors} errors", end='', flush=True)
        batch = []

    except Exception as e:
      errors += 1
      print(f"\n[!] {str(e)}")

  # Flush remaining
  if batch:
    response = client.bulk(body=batch, refresh=False)
    if response.get('errors'):
      errors += sum(1 for item in response['items'] if item['delete'].get('error'))
    total += len(batch)

  client.indices.refresh(index=index)
  print(f"\n[+] Done: {total} documents deleted, {errors} errors")

def drop(index):
  response = client.indices.delete(
      index = index
  )
  print(response)

def copy(index_src, index_dst):
  response = client.reindex(
    body = {
      "source":{"index": index_src},
      "dest":{"index": index_dst}
    }
  )
  print(response)

if args.init:
  init(index=args.index)
elif args.drop:
  drop(index=args.index)
elif args.copy_index:
  copy(index_src=args.index, index_dst=args.copy_index)
elif args.file_import:
  add(index=args.index, source=args.file_import)
elif args.file_delete:
  delete(index=args.index, source=args.file_delete)
elif args.query:
  query(index=args.index, text=args.query)
elif args.cache:
  cache(index=args.index, _id=args.cache)
else:
  if args.index:
    info(index=args.index)
  else:
    indexes()
