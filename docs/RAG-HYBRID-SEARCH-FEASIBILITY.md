# Feasibility & Design — Intelligent RAG + Hybrid Search, *Additive* to recoll

**Status:** design assessment only. **No install.** Nothing here touches or changes the working
recoll + tesseract Xapian index. Re-validate every model fact at deploy time — this space moves fast.

**Date:** 2026-06-24 · **Author:** archive toolkit (Claude-assisted deep research, 23 sources, 25
claims adversarially verified → 17 confirmed / 8 refuted). Source list at the bottom.

---

## 1. Bottom line

Adding a RAG + hybrid (dense+sparse) search layer to this box is **feasible, but only in a
deliberately minimal, memory-budgeted, strictly-additive configuration.**

- **The binding constraint is RAM, not CPU and not disk.** The box has ~14 GiB usable and realistically
  **~8–11 GiB free at rest** (Immich's postgres+redis+node, copyparty, Samba, recoll-web, restic/kopia
  already resident). Every design choice below bends around that number. NVMe has 514 GB free (plenty for
  models + vectors); the archive HDD is 86% full and must **not** be used for derived data.
- **The single rule that makes it safe:** never hold two heavy stages resident at once. Parser, embedder,
  and any generation model load **one at a time, on demand**, each its own process, each on NVMe, none
  ever opening or locking recoll's DB.
- **Two numbers we do NOT yet have** (the research could not source them and they must be measured on the
  actual box before committing): (a) llama.cpp generation tokens/sec for the 4B vs 35B-A3B models on this
  AVX2-without-AVX-512 CPU, and (b) real OCR-enabled Docling throughput on scanned pages. See §8.

---

## 2. Per-component assessment & footprint

RAM figures are *resident working set*; "peak" = peak RSS during processing. Items marked **[unmeasured]**
are engineering estimates or gaps the research explicitly could not close — treat as hypotheses to test,
not facts.

| Component | Choice | Resident RAM | On-disk | Verdict |
|---|---|---|---|---|
| **Parser (light)** | granite-docling-258M | **~0.5 GB** | 515 MB | Tiny footprint, but **15–20 min/doc on CPU** → overnight-churn only |
| **Parser (standard)** | Docling, **pypdfium** backend | **~2.4 GB** peak | — | Recommended parser. Throughput benchmark was **OCR-OFF**; real scans slower **[unmeasured]** |
| Parser (heavy) | Docling, native backend | ~6.16 GB peak | — | Too heavy here; also a batch **memory leak** (issue #2788) |
| **Embedder (pick)** | **BGE-M3** (568M, FP16) | **~1.2–1.3 GB** | ~1.2 GB | Emits dense **+ sparse + ColBERT** natively — exactly what hybrid needs |
| Embedder (VL alt) | Qwen3-VL-Embedding-2B | ~4 GB weights / **~10 GB** min inference | ~4 GB | **Rejected** on the text path (see below) |
| Embedder (max) | Qwen3-Embedding-4B | **12–18 GB** working | ~2.5 GB | Does not fit; offline one-shot only |
| Reranker | Qwen3-VL-Reranker-2B | ~4 GB if resident | ~4 GB | On-demand cold-load latency **[unmeasured]** — deciding factor |
| Generation (fits) | Qwen3.5-4B, Q4/Q5 | ~2.5–3 GB **[est]** | ~2.5 GB | Fits RAM; tok/s on this CPU **[unmeasured]** |
| Generation (MoE) | Qwen3.6-35B-A3B, Q4 | ~20 GB → **mmap from NVMe** | ~18–20 GB | Does **not** fit RAM; viability **[unmeasured]**, likely slow (see below) |
| **Vector store** | **Milvus Lite** | small (embedded) | TBD on subset | pip-install, no Docker, local `.db`, native dense+sparse hybrid |

### Why these picks

**Docling → scanned subset only, never the whole corpus.** The standard pipeline's peak RSS is 6.16 GB
native / **2.4 GB pypdfium** — and *every* published throughput number was measured with **OCR disabled**
on born-digital pages. The Docling report itself calls OCR "the most expensive operation" (disabling it
"saves 60% of runtime"; EasyOCR ~13 s/page on x86). For a **scan-heavy** corpus the real per-page cost is
materially worse and unmeasured. Conclusion: point Docling only at the scanned-PDF subset (recoll+tesseract
already handle born-digital text well), use the lighter pypdfium backend, and run it sequentially.

**Docling's `document_timeout` is broken — a real risk for this corpus.** Confirmed open bug (#2381): a
single PDF page with ~40k XObjects hangs `convert()` for >1 hr, ignoring the timeout, un-interruptible by
Ctrl-C; maintainers confirm "timeout only checks *between* batches." With tens of thousands of carved
fragments (~18% file-error rate), pathological PDFs are expected. **Mitigation: wrap each conversion in an
OS-level (external process) timeout, run workers out-of-process so a hung one can be killed, and quarantine
over-budget files** — never rely on the library's own timeout.

**BGE-M3 over Qwen3-VL-Embedding-2B on the text path.** BGE-M3 is the only candidate that simultaneously
produces dense + sparse-lexical + ColBERT multi-vectors (the dense+sparse pairing the hybrid store wants),
at ~1.2 GB. The 2B VL model's *real* footprint gap is ~8–10× (its card reports ~10 GB minimum inference
memory), and — per its own paper — it scores **worse than same-size text-only models on text retrieval**;
BGE-M3 (0.6B) trails it by only ~4 MMTEB points. The VL model's advantage only appears when you feed page
**images**, which is a *different* pipeline (an alternative to recoll+tesseract), not a text drop-in.
*Caveat: no source benchmarked embedding quality on noisy OCR specifically, so this ranking is inferred.*

**Milvus Lite over LanceDB for the store.** Milvus Lite is a pip-installable **embedded** library (no
Docker, no server) persisting to a local `.db` file, with native single-call dense+sparse `hybrid_search`
well-matched to BGE-M3. LanceDB is also embedded, but its IVF/PQ index **build is memory-intensive** — a
practitioner report had it run ~1 day then OOM at 700M vectors *on a 128 GB machine* (illustrative upper
bound; our corpus is ~700k–1M, ~1000× smaller, so a single build is likely fine, but **any ANN build must
be batched with `optimize()` between chunks and nothing else resident** — it's the peak-RAM event).
*Caveat: whether Milvus Lite supports the server-side BM25 *function* is unconfirmed; the safe design is to
let BGE-M3 emit the sparse vectors and store them as `SPARSE_FLOAT_VECTOR` (works in any Milvus mode). If
server-side BM25 turns out to need Standalone, that is the one place a Docker component might appear.*

**Generation tier is the biggest open question.** No source quantified llama.cpp tok/s for Qwen3.5-4B vs
Qwen3.6-35B-A3B on AVX2-without-AVX-512, nor the practicality of mmap-ing the 35B-A3B's ~20 GB of weights
from NVMe. The nearest data point is sobering: a comparable 3B-active MoE (Qwen3-Next-80B-A3B, Q4, 51 GB)
managed only **7.74 tok/s on a 12c/24t Ryzen that *has* AVX-512** — our T-part CPU is weaker and lacks
AVX-512, and mmap page-faulting 20 GB/token-ish from disk adds latency. **The 4B model is the safe default
(fits RAM); the 35B-A3B is "benchmark before believing."**

---

## 3. Strictly-additive, read-only coexistence with recoll

By construction, nothing in the recommended stack can jeopardize the existing index:

1. **Separate processes, separate storage.** The vector store is a self-contained Milvus Lite `.db` file on
   NVMe; the parser/embedder write only to the new vector-store path. None of them open, lock, or share
   recoll's ~18 GB Xapian DB.
2. **The new pipeline consumes recoll/tesseract *output* or reads sources read-only** — it never writes
   into `incoming/` masters or the recoll index.
3. **Everything on the 514 GB NVMe**, never the 86%-full archive HDD.
4. **On-demand / sequential model loading** so resident RAM never forces the always-on family services
   (Immich/postgres/redis, copyparty, Samba) into swap.
5. **Independent systemd units / containers** that can be stopped or disabled with **zero effect on recoll**.
   If the experiment fails or misbehaves, `systemctl stop` + delete one directory and the box is exactly as
   it is today.

---

## 4. Dominant failure modes & mitigations

| Failure mode | Mitigation |
|---|---|
| **OOM / swap-thrash** from stacking parser + embedder + LLM resident | Load **one heavy stage at a time**; never co-resident; cap worker concurrency; watch `MemAvailable` |
| **Docling hangs** on a pathological scan (broken `document_timeout`) | **External OS-level per-doc timeout**, out-of-process workers, quarantine over-budget files |
| **Docling batch memory leak** (#2788) | Process in bounded batches, restart the worker between batches |
| **ANN index build peak RAM** | Batch/incremental build, `optimize()` between chunks, nothing else loaded |
| **Vector-store corruption** | It's a *separate* file — corruption there never touches recoll; rebuildable from masters |
| **Model/leaderboard drift** | Re-verify embedder scores & Docling OCR-backend defaults at deploy (v2.56 already swapped EasyOCR→RapidOCR) |

---

## 5. Recommended **minimal** architecture (fits ~10 GiB)

```
scanned-PDF subset ──► Docling (pypdfium, external timeout, out-of-process)
                            │  [load → run → unload]
                            ▼
                       chunk text ──► BGE-M3 embed (dense + sparse)
                            │  [load → embed batch → unload]
                            ▼
                       Milvus Lite  (local .db on NVMe; dense+sparse hybrid_search)
                            ▲
   query ──► BGE-M3 (query embed) ──► hybrid_search ──► [optional] rerank ──► [optional] Qwen3.5-4B answer
```

- Parser: **Docling/pypdfium** on the scanned subset (or **granite-docling-258M** if footprint must be
  rock-bottom and we accept overnight throughput).
- Embedder: **BGE-M3**, dense + sparse stored side by side.
- Store: **Milvus Lite**, embedded, NVMe.
- Generation (optional): **Qwen3.5-4B Q4** — only loaded when a question is actually asked.
- Reranker (optional): **on-demand only**, pending the latency test (§8).

## 6. Optional **"max quality, churn for days"** variant

Same shape, but run as a one-shot offline pass with **nothing else loaded**: swap BGE-M3 for a 4B/8B-class
text embedder (12–18 GB working — only possible with services paused), and/or attempt the 35B-A3B MoE for
generation with weights mmap'd from NVMe. Both are **benchmark-gated** (§8) and not part of the standing,
always-available stack. The box "churns for as long as needed" is acceptable *only* if memory is freed for
the duration; otherwise it swaps and starves the family services.

---

## 7. Phased, low-risk pilot

1. **Smallest proof of value (no commitment).** Take a few hundred representative scanned PDFs — the
   **estate-document subset is the perfect first batch** (we're already hunting in it). Run Docling
   (pypdfium + external timeout) → BGE-M3 → Milvus Lite → a few hybrid queries. **Measure: OCR-on Docling
   sec/page, peak RAM, vector-store size, and retrieval quality vs recoll** on the same queries.
2. **Benchmark the generation tier on the box** (Qwen3.5-4B vs 35B-A3B mmap: tok/s, RAM, swap behavior)
   *before* choosing a generation model.
3. **Benchmark reranker on-demand cold-load latency** — decides whether reranking is viable at all here.
4. **Only then** decide full-corpus scope (almost certainly the scanned subset, not all 176k/958k files)
   and let it run overnight/over days with services memory-budgeted.

Each phase is independently abortable and leaves recoll untouched.

---

## 8. Open questions — must be measured on *this* box

1. **Generation tok/s (largest gap):** Qwen3.5-4B vs Qwen3.6-35B-A3B (Q4/Q5) on AVX2 / no-AVX-512, and
   whether 35B-A3B mmap'd from NVMe is usable. Nearest reference: 7.74 tok/s for a 3B-active MoE on a
   *stronger* AVX-512 box.
2. **OCR-enabled Docling throughput** on the throttled i5-10500T (all published numbers are OCR-off,
   born-digital).
3. **Milvus Lite** server-side BM25 support, and its real idle/working RAM + on-disk size for ~700k–1M
   BGE-M3 dense+sparse vectors.
4. **Reranker on-demand** per-query cold-load latency for a 2B reranker on CPU.

---

## 9. What the research *refuted* (don't repeat these)

Eight plausible-sounding claims were killed in verification, including: a clean "0.6–0.9 pages/sec CPU
ceiling" for Docling (the cited figure was OCR-off and didn't generalize); a "6× GPU-vs-CPU" Docling
speedup; "BGE-M3 ONNX = 3× faster on CPU"; "Milvus full-text search is unavailable in Lite"; and a
"~2.3 KB/vector on disk" LanceDB figure. Net effect: **absolute full-corpus indexing wall-clock time and
on-disk vector-store size remain only loosely bounded** until the pilot measures them.

---

## 10. Sources (primary first)

- Docling Technical Report (IBM), arXiv 2408.09869v5 — CPU throughput/memory, OCR cost
- Docling issue #2381 — `document_timeout` broken on 40k-XObject page (+ #2109, #2478, #2788 leak)
- ibm-granite/granite-docling-258M (HF card) — 258M VLM, 515 MB, CPU 15–20 min/doc
- Qwen3-VL-Embedding paper, arXiv 2601.04720 — VL embedder scores below text-only peers on text
- BAAI/bge-m3 (HF card) — 568M, dense+sparse+ColBERT, 8192 ctx
- QwenLM/Qwen3-Embedding (repo + 4B/8B HF cards) — higher-tier params/footprint
- Milvus docs: full_text_search_with_milvus, milvus_lite; PyPI milvus-lite — embedded + hybrid
- sprytnyk.dev "Running LanceDB in production" + lancedb issue #1500 — IVF build OOM at scale
- llama.cpp issue #19480, HF "llamacpp-moe-offload-guide" — MoE CPU/mmap data points

*Full per-claim evidence, confidence, and vote tallies are in the research run output
(`tasks/w4cd0ank1.output`); this doc is the synthesized, deployable summary.*
