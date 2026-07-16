# rag-pilot — Phase-1 feasibility pilot (Docling → BGE-M3 → Milvus Lite)

**Status: PLAN / REVIEW. Nothing here installs or runs until you run it with `--go`.**
This is the smallest experiment that measures whether the RAG stack from
`docs/RAG-HYBRID-SEARCH-FEASIBILITY.md` is practical on *this* box, over a few hundred scanned PDFs.
It does **not** replace or touch recoll.

## Safety properties (why this can't hurt the archive)

- **Everything lives under `RAG_HOME` (default `/home/tom/rag-pilot`) on the NVMe** — never the archive HDD,
  never `/srv/archive`. `run.sh` refuses to run if `RAG_HOME` is under the archive.
- **Sources are read-only.** The pilot only ever *reads* PDFs from the archive and *writes* under `RAG_HOME`.
- **The recoll / Xapian index is never opened, locked, or modified.** Separate process, separate storage.
- **One heavy model at a time.** Parsing (Docling) and embedding (BGE-M3) run as *separate processes*, so
  they never sit in RAM together. A memory floor (`MIN_FREE_MIB`, default 3 GiB) aborts a stage rather than
  risk swapping the family services.
- **Docling can't hang the run.** Each PDF is parsed in its own subprocess under an **OS-level `timeout`**
  (default 180 s, `timeout -k`), because Docling's own `document_timeout` is a known-broken hang risk.
  Over-budget/failed files are quarantined and the run continues.
- **CPU-only.** Torch is installed from the CPU wheel index (no CUDA pulled).
- **Fully reversible.** `run.sh teardown --go` deletes the entire `RAG_HOME` (venv, models, vector DB, logs)
  in one shot. Nothing outside it is touched.
- **Mutating steps dry-run by default.** `setup`, `select`, `parse`, `embed`, `teardown` print what they
  would do and require `--go` to act.

## Footprint (estimate — the pilot will MEASURE the real numbers)

| Item | Est. size | Where |
|---|---|---|
| Python venv + CPU torch + deps | ~3–5 GB | `RAG_HOME/venv` |
| Models (BGE-M3 ~1.2 GB + Docling layout/OCR) | ~2–4 GB | `RAG_HOME/models` |
| Vector DB (few hundred docs) | tens–hundreds of MB | `RAG_HOME/milvus.db` |
| Peak RAM during embed | to be measured | (one model resident) |

All on the NVMe (514 GB free). The archive HDD (86 % full) is never written.

## Run sequence

```
./run.sh setup --go                         # venv + CPU-only deps (BIG download; first install only)
./run.sh select "/srv/archive/recovered/mary-ext-hitachi-1tb" 200 --go   # pick ≤200 scanned PDFs
./run.sh parse --go                         # Docling-parse them (180s OS-timeout each)
./run.sh embed --go                         # BGE-M3 → Milvus Lite (dense+sparse)
./run.sh query "small estate affidavit hartigan"   # hybrid search demo
./run.sh measure                            # footprint + timings
./run.sh teardown --go                      # delete the whole pilot
```

Tunables (env): `RAG_HOME`, `DOC_TIMEOUT`, `MIN_FREE_MIB`, `SUBSET_MAX`.

## What we measure (the point of the pilot)

1. **Docling OCR throughput** on this CPU — real seconds/page (the assessment's #1 unknown).
   `parse_one.py` separates model-load time from convert time so the per-page number is honest.
2. **Peak RAM** during embed (via `/usr/bin/time -v`).
3. **Vector-store size** for the subset (extrapolates to full-corpus).
4. **Retrieval quality** — does hybrid search find things recoll does, and the scanned content?

## Known things to re-verify AT INSTALL (flagged in the code as VERIFY-AT-INSTALL)

- Docling advanced-options import paths / option names shift between releases (pin after a good install).
- Milvus Lite sparse-vector insert/slice format (`csr[[i]]`) and `hybrid_search` signature.
- After a known-good install, `pip freeze > requirements.lock.txt` and pin to it.

## NOT in scope for Phase 1

Generation (Qwen3.5-4B vs 35B-A3B tok/s) and reranking — those are a separate, even smaller
benchmark (assessment §8). This pilot is parse + embed + hybrid-retrieve only.
