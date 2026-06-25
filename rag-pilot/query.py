#!/usr/bin/env python3
"""query.py DB_PATH "query text"  —  hybrid (dense + sparse) search over the pilot vector store.

Embeds the query with BGE-M3, runs Milvus hybrid_search fusing a dense and a sparse AnnSearchRequest
with WeightedRanker, and prints the top hits (source path + snippet). Read-only against DB_PATH.

VERIFY-AT-INSTALL: AnnSearchRequest / WeightedRanker / hybrid_search signatures and the sparse query
slice (`q["sparse"][0:1]`) match the current Milvus BGE-M3 hybrid tutorial; re-check at install.
"""
import sys

COLL = "pilot"
TOPK = 8


def main():
    if len(sys.argv) < 3:
        print('usage: query.py DB_PATH "query text"', file=sys.stderr)
        return 2
    db = sys.argv[1]
    query = " ".join(sys.argv[2:])

    from pymilvus import connections, Collection, AnnSearchRequest, WeightedRanker
    from pymilvus.model.hybrid import BGEM3EmbeddingFunction

    ef = BGEM3EmbeddingFunction(use_fp16=False, device="cpu")
    connections.connect(uri=db)
    col = Collection(COLL)
    col.load()

    q = ef([query])
    dense_req = AnnSearchRequest([q["dense"][0]], "dense_vector",
                                 {"metric_type": "IP", "params": {}}, limit=TOPK)
    sparse_req = AnnSearchRequest([q["sparse"][0:1]], "sparse_vector",
                                  {"metric_type": "IP", "params": {}}, limit=TOPK)
    hits = col.hybrid_search([sparse_req, dense_req], rerank=WeightedRanker(1.0, 1.0),
                             limit=TOPK, output_fields=["text", "src"])[0]

    print(f'query: {query!r}\n{"-" * 60}')
    for h in hits:
        ent = h.entity
        src = ent.get("src") if hasattr(ent, "get") else ent["src"]
        txt = ent.get("text") if hasattr(ent, "get") else ent["text"]
        snippet = " ".join((txt or "").split())[:220]
        print(f"[{h.distance:.3f}] {src}\n    {snippet}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
