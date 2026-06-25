#!/usr/bin/env python3
"""embed_store.py PARSED_DIR DB_PATH  —  embed parsed text with BGE-M3 (dense+sparse) into Milvus Lite.

Runs in its OWN process, after Docling has exited, so BGE-M3 and Docling never sit in RAM together.
Chunks each parsed doc, embeds in modest batches (bounded memory), and inserts dense + sparse vectors
into a local Milvus Lite file (DB_PATH). Writes only DB_PATH.

VERIFY-AT-INSTALL: the sparse-matrix slice format for insert (`sparse[i:i+1]`) and the exact
BGEM3EmbeddingFunction return keys ("dense"/"sparse") should be re-checked against the installed
pymilvus version; both match the current Milvus BGE-M3 hybrid tutorial.
"""
import glob
import json
import os
import sys

CHUNK = 1500      # chars per chunk (rough; refine after the pilot)
OVERLAP = 200
BATCH = 64        # chunks embedded+inserted per batch -> bounded RAM
COLL = "pilot"


def chunks(text):
    text = " ".join((text or "").split())
    i = 0
    while i < len(text):
        piece = text[i:i + CHUNK]
        if piece.strip():
            yield piece
        i += max(1, CHUNK - OVERLAP)


def main():
    if len(sys.argv) != 3:
        print("usage: embed_store.py PARSED_DIR DB_PATH", file=sys.stderr)
        return 2
    parsed_dir, db = sys.argv[1], sys.argv[2]

    files = sorted(glob.glob(os.path.join(parsed_dir, "*.json")))
    if not files:
        print("no parsed *.json found", file=sys.stderr)
        return 1

    rows = []
    for fp in files:
        try:
            rec = json.load(open(fp))
        except Exception as e:
            print(f"skip {fp}: {e}", file=sys.stderr)
            continue
        for ci, ch in enumerate(chunks(rec.get("text", ""))):
            rows.append((rec.get("path", fp), ci, ch))
    if not rows:
        print("no non-empty chunks", file=sys.stderr)
        return 1
    print(f"{len(rows)} chunks from {len(files)} docs")

    from pymilvus import (connections, utility, FieldSchema, CollectionSchema,
                          DataType, Collection)
    from pymilvus.model.hybrid import BGEM3EmbeddingFunction

    ef = BGEM3EmbeddingFunction(use_fp16=False, device="cpu")
    dense_dim = ef.dim["dense"]

    connections.connect(uri=db)  # Milvus Lite: a local file
    fields = [
        FieldSchema(name="pk", dtype=DataType.VARCHAR, is_primary=True, auto_id=True, max_length=100),
        FieldSchema(name="text", dtype=DataType.VARCHAR, max_length=8192),
        FieldSchema(name="src", dtype=DataType.VARCHAR, max_length=4096),
        FieldSchema(name="chunk", dtype=DataType.INT64),
        FieldSchema(name="sparse_vector", dtype=DataType.SPARSE_FLOAT_VECTOR),
        FieldSchema(name="dense_vector", dtype=DataType.FLOAT_VECTOR, dim=dense_dim),
    ]
    schema = CollectionSchema(fields, description="rag-pilot")
    if utility.has_collection(COLL):
        utility.drop_collection(COLL)
    col = Collection(COLL, schema, consistency_level="Strong")
    col.create_index("sparse_vector", {"index_type": "SPARSE_INVERTED_INDEX", "metric_type": "IP"})
    col.create_index("dense_vector", {"index_type": "AUTOINDEX", "metric_type": "IP"})
    col.load()

    inserted = 0
    for b in range(0, len(rows), BATCH):
        batch = rows[b:b + BATCH]
        texts = [r[2][:8000] for r in batch]
        emb = ef(texts)  # {"dense": ndarray[n,dim], "sparse": csr[n,V]}
        col.insert([
            texts,
            [r[0][:4000] for r in batch],
            [int(r[1]) for r in batch],
            emb["sparse"],
            emb["dense"],
        ])
        inserted += len(batch)
        print(f"  inserted {inserted}/{len(rows)}")
    col.flush()
    print(f"done: {inserted} chunks into {db} (collection '{COLL}', dense_dim={dense_dim})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
