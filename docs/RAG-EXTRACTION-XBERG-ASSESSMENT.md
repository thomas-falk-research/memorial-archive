# Revision to the RAG design — replace Docling with **xberg / Kreuzberg** as the extraction tier

**Status:** design revision. **No install.** Amends `docs/RAG-HYBRID-SEARCH-FEASIBILITY.md` §2, §5, §7.
Nothing here touches masters, the recoll index, or the running family services.

**Date:** 2026-07-27 · Companion to the original assessment; same rule — every unmeasured number is
marked **[unmeasured]**, and vendor-published numbers are labelled as such.

---

## 1. Bottom line

**Swap the parser. Keep everything else.** The original design named Docling as the extraction tier and
then spent half a page apologising for it: a broken `document_timeout` that hangs forever on
pathological PDFs, a batch memory leak, ~1 GB of Python dependencies, a PyTorch requirement, and
throughput numbers that were all measured with **OCR off** — on a corpus that is mostly scans.

xberg (the Rust successor to Kreuzberg) removes those problems rather than mitigating them, and it
brings one capability Docling never had that matters more here than any benchmark:

> **It reads PST, MSG, EML and ZIP/TAR/7Z natively, and extracts recursively** — mailbox → message →
> attachment → the scan inside it. That is precisely the shape of the thing we have been hunting for
> months: John Sr.'s will, trust and death certificate exist as **faxed scans attached to email**.

That single fact justifies the change on its own. The performance and footprint gains are a bonus.

**Recommended architecture change:**

```
  before:  scanned-PDF subset ──► Docling (torch, pypdfium, external timeout) ──► chunk ──► BGE-M3 ──► Milvus Lite
  after:   PST / EML / PDF / TIFF ──► xberg (Rust, PDFium, Tesseract) ──► chunk ──► BGE-M3 ──► Milvus Lite
                                        └─ recursive: attachments, archives, embedded images
```

**But it is not a free lunch, and §4 is the part to read before agreeing.** The ecosystem is mid-rebrand
and mid-release; picking a version is a real decision, not a formality.

---

## 2. What the swap actually buys

| | Docling (original pick) | xberg / Kreuzberg |
|---|---|---|
| Core | Python + **PyTorch** | **Rust** (PDFium text extraction, ONNX Runtime, Rayon parallelism) |
| Install footprint | **~1,032 MB**, heavy dep tree | **~71 MB, ~20 deps** (vendor-published) |
| Parse-stage RAM | ~2.4 GB peak (pypdfium) / 6.16 GB (native) | far lower **[unmeasured — the number we must produce]** |
| Hang risk | **`document_timeout` is broken** (issue #2381): >1 hr hangs, un-interruptible | no equivalent known defect; we keep the OS-level timeout anyway |
| Memory leak | **batch leak** (issue #2788) → must restart workers between batches | not applicable |
| Throughput | slow on CPU; *every* published figure was **OCR-off** | vendor claims **35+ files/sec** and "Docling often 60+ min/file" |
| **Mailbox formats** | ✗ | **PST, MSG, EML — with recursive attachment extraction** |
| **Archive formats** | ✗ | ZIP, TAR, 7Z, recursive |
| **Fax/scan formats** | PDF-centric | TIFF, **JBIG2** (the fax codec), HEIC, JPEG2000, WebP, SVG |
| Office formats | limited | Word/Excel/PowerPoint/ODF/**HWP**/EPUB — no Tika, no Gotenberg |
| Dedup | none | **content-hash cache** — re-extraction is skipped automatically |
| Interfaces | Python library | Rust lib, **Python**, CLI, REST server, **MCP server**, Docker |

**Caveat, stated plainly:** the speed and footprint figures are the project's **own** benchmarks, and I
could not find an independent replication. Treat them as a hypothesis. What is *architecturally*
verifiable — Rust core, PDFium, ONNX instead of PyTorch, 20 deps instead of a torch tree — is enough to
justify the pilot on its own, and our own assessment already independently found Docling-class CPU
parsing to be 15–20 min/doc for the small VLM variant. The two stories are consistent.

### The knock-on win: PyTorch may disappear entirely

The original pilot budgeted **~3–5 GB** for a venv, mostly CPU torch, because both Docling *and* BGE-M3
needed it. With xberg the parse stage needs no torch at all, and xberg additionally offers **local ONNX
embeddings**. If an ONNX embedder can produce what the hybrid store needs (dense **plus** sparse), the
entire stack becomes Rust + ONNX with **no PyTorch anywhere** — a different order of resource cost on a
box whose binding constraint is RAM.

**Open question (§6):** whether BGE-M3's *sparse* vectors are available through xberg's ONNX path. If
not, keep BGE-M3 on torch for the embed stage only — still a large win, since parse and embed already
run as separate, never-co-resident processes.

---

## 3. What this changes about the corpus — and the will hunt

The original Phase-1 pilot was "a few hundred scanned PDFs". With native mailbox support, the obvious
first target changes:

**Point it at `Outlook MKH.pst` (1.67 GB) directly** — read-only, from a copy — and let it walk every
message, every attachment, and every image inside those attachments, OCR'ing as it goes. That is the
prime remaining place the estate documents can be hiding, and it is exactly the traversal that
`FaxImage.tif` / `image001.gif` / `SKM_*.pdf` attachments have so far survived by being meaninglessly
named. Search is by *content*, so a meaningless filename stops mattering.

This does not replace recoll (which already indexes the extracted PST) — it adds semantic retrieval over
the same material, and it re-walks the attachment tree with a different extractor, which is itself a
second opinion on a corpus we have failed to crack twice.

**Standing rule unchanged:** third parties' private documents (the cousins' material) stay out of scope —
extraction is pointed at our own sources, not the whole tree.

---

## 4. Maturity, licensing, and the version decision — read this before agreeing

This is where the honest reservations live.

1. **The project is mid-rebrand.** Kreuzberg → xberg is "the next iteration … rebuilt and rebranded under
   a fresh v1 line". The canonical Python package is still **`kreuzberg`**; `xberg` on PyPI is currently
   an **alias package**.
2. **It is mid-release, right now.** PyPI shows **1.0.0rc8 → 1.0.0rc42 published between 5 and 27 July
   2026** — 34 release candidates in three weeks, the most recent **today**. A 1.0.0 final looks
   imminent, which argues for waiting days, not weeks.
3. **The GitHub README says MIT; the PyPI `xberg` alias package says Elastic-2.0.** The v4 LTS repo is
   explicitly MIT. This is most likely stale metadata on a placeholder package, but **the licence must be
   confirmed from the actual artifact we install**, not from a README.
4. **`pip install xberg` does not install xberg.** Its only *stable* PyPI release is the **0.1.0
   placeholder alias**; the real code ships as `1.0.0rc8…rc42` pre-releases, which **pip ignores unless
   you pass `--pre`**. Installing the bare name yields a package that imports but extracts nothing — and
   would sail through a naive egress test by doing nothing at all, twice. The verification script pins a
   version, adds `--pre` automatically for release-candidate pins, and **refuses to certify a package
   with no extraction entry point**.
5. **Kreuzberg v4 is not as legacy as its "LTS" label suggests.** Despite being described as superseded,
   **4.10.0, 4.10.1 and 4.10.2 all shipped on 11–12 July 2026** — two weeks ago. It is MIT, publishes a
   `manylinux_2_28_x86_64` wheel, and has a `tesseract` extra for the local OCR backend. That makes the
   "conservative" option a genuinely current one rather than a compromise.

**How much does this churn actually matter?** Less than it would anywhere else in this archive, and it is
worth being precise about why:

> The extraction pipeline is **read-only and derived**. It reads copies, writes only into its own area on
> the NVMe, and never opens the recoll index or a master. If the library breaks, regresses, or gets
> renamed again, the cost is **re-running an extraction** — wasted CPU time, not lost data. That is a
> categorically different risk from the Paperless ingest we just stepped back from, where the tool
> *deletes* what it consumes.

So the maturity risk is real but bounded, and it argues for one design rule rather than for waiting:

> **Treat the extractor as a swappable stage.** The pilot already has the right seam — `parse_one.py SRC
> OUT.json`, one process per file under an OS-level timeout. Keep that contract, add an xberg
> implementation beside the Docling one, and the choice of engine becomes a one-line change instead of a
> commitment.

**Recommendation (revised after checking PyPI):** start on **`kreuzberg[tesseract]==4.10.2`** — canonical
package, MIT, current, real wheel, local OCR — and move to **xberg 1.0.0** once it goes final. This gets
measurements this week on a stable artifact instead of waiting on a release candidate, and because the
extractor is a swappable stage the move costs one line later. Record the exact pin; do **not** float the
version — same discipline as every other pin in this repo.

*Note on capability while pinned to v4:* the mailbox/recursive-archive reach described in §3 is
advertised for the **xberg (v5) line**. Confirm which of PST/MSG/EML the pinned v4 build actually handles
before Phase 2 depends on it — if the answer is "not PST", that alone is the argument for taking the rc.

---

## 5. Safety verification — what I confirmed, and the gate that is still open

A document-intelligence library that advertises "143+ LLM providers", cloud VLM OCR and remote embedding
APIs deserves exactly the scrutiny this archive's rules demand. What the documentation establishes:

| Check | Finding |
|---|---|
| Default OCR backend | **Tesseract, fully local.** No network path in the default configuration. ✅ |
| Cloud / VLM OCR (GPT-4V, Claude Vision, Gemini) | **Strictly opt-in** — inert unless you configure a model *and* supply an API key. ✅ |
| Remote embedding APIs | Same: opt-in, key-gated. Local ONNX is the alternative. ✅ |
| PaddleOCR / ONNX model weights | **Downloaded automatically on first use**, then cached locally. ⚠ First run needs network; documented air-gapped pre-fetch **not found**. |
| Telemetry / observability | Ships **as a module**; whether anything is enabled by default is **NOT documented and NOT confirmed**. ⛔ |

**The blocking gate: nothing points at a single family document until we have proven the extractor makes
no outbound connection.** Model weights downloading once is acceptable; a document — or a hash, or a
filename, or a "usage event" — leaving this box is not, ever.

The test is simple and decisive, and it is written: `rag-pilot/verify-xberg-offline.sh` installs the
pinned version into a throwaway venv on the NVMe, extracts **synthetic** documents it generates itself,
and then **re-runs the identical extraction with the network namespace removed** (`unshare -rn`). If the
results are byte-identical with no network at all, the library provably needs no egress at runtime. It
also inspects the installed package for telemetry defaults and reports every environment variable that
could enable a remote backend. Only after it passes clean does anything real get parsed.

---

## 6. Revised open questions — to be measured on *this* box

Replacing the original assessment's parser questions:

1. **xberg OCR-on throughput** on the i5-10500T: real seconds/page on our actual faxes and scans. This
   was the #1 unknown before and remains #1 — only the subject changed.
2. **Peak RSS during extraction**, including the worst real inputs we own (large multi-page TIFF faxes,
   the 1.67 GB PST).
3. **PST traversal correctness** — does it enumerate every message and attachment, and does the recursive
   image extraction actually reach the fax scans? Cross-check the count against our existing PST extraction.
4. **Does the ONNX embedding path emit sparse vectors** (BGE-M3-equivalent), i.e. can PyTorch leave the
   box entirely? (§2)
5. **Telemetry/egress: zero** (§5) — a gate, not a measurement.
6. **Licence of the actual installed artifact** (§4.3).

Carried over unchanged from the original assessment: generation tok/s on AVX2-without-AVX-512, reranker
cold-load latency, and Milvus Lite's real footprint.

---

## 7. Revised phased plan

| Phase | What | Gate |
|---|---|---|
| **0** | **Egress/telemetry verification** on synthetic data, network-namespace test (§5) | ← **do this first, always** |
| **1** | Extract a few hundred real scanned PDFs; measure sec/page, peak RAM, quality vs recoll | phase 0 clean |
| **2** | **Point it at the PST** — recursive attachment + image extraction, OCR on. Compare the attachment inventory against our existing extraction | phase 1 measured |
| **3** | Embed (BGE-M3 or ONNX) → Milvus Lite → hybrid queries, including the estate-specific terms | phase 2 useful |
| **4** | Decide full-corpus scope and let it churn overnight/over days, memory-budgeted | measured, reviewed |

Every phase reads copies, writes only under `RAG_HOME` on the NVMe, and is deleted by
`run.sh teardown --go`. recoll, Immich, copyparty and the masters are untouched throughout.

---

## 8. What happens to the Paperless work

Parked, not deleted — `docs/PAPERLESS-DOCUMENT-VIEW.md` stands as the design if the family ever wants a
curated document shelf. Your instinct on the trade was right: Paperless demands per-document curation
labour and a **delete-on-consume** ingest, for a payoff that is organisational; this pipeline is
read-only, needs no curation, and gets *more* valuable as it is pointed at more material.

**The version guard that landed alongside it stays, and is worth keeping regardless** — it protects the
Paperless install that already exists on the box from an unattended v2→v3 migration that would blank its
database. That hazard is independent of whether we ever feed it another document.

---

## 9. Sources

- xberg README (xberg-io/xberg) — Rust engine, 98 formats incl. PST/MSG/EML and ZIP/TAR/7Z recursive
  extraction, TIFF/JBIG2/HEIC, OCR backends (Tesseract native FFI, PaddleOCR ONNX, Candle, opt-in VLM),
  local ONNX embeddings, CLI/REST/MCP/Docker, 15 language bindings; 8.7k stars, 7,679 commits, 7 open issues
- PyPI `xberg` — only stable release is **0.1.0** (a placeholder alias); real code published as
  1.0.0rc8 … rc42, 5–27 July 2026, i.e. **pre-releases pip skips by default**; metadata declares
  Elastic-2.0 (**conflicts with the README's MIT — verify at install**)
- PyPI `kreuzberg` — latest stable **4.10.2 (12 July 2026)**, MIT, `manylinux_2_28_x86_64` wheel,
  extras `tesseract` / `easyocr` / `all`; a 5.0.0rc3 also exists
- kreuzberg-dev/kreuzberg-lts — "Kreuzberg v4 LTS … legacy; superseded by xberg for v5+. MIT-licensed";
  critical fixes to end of 2026, best-effort
- docs.kreuzberg.dev `/guides/ocr/` — Tesseract is the default backend and runs fully locally; PaddleOCR
  ONNX models auto-download on first use and cache; **cloud/VLM backends require explicit configuration
  and an API key**
- Kreuzberg vendor benchmarks (Medium/DEV) — 35+ files/sec, ~71 MB / 20 deps vs Docling ~1,032 MB,
  Rust + PDFium + ONNX + Rayon; **self-published, not independently replicated**
- `docs/RAG-HYBRID-SEARCH-FEASIBILITY.md` (this repo) — Docling issues #2381 (broken `document_timeout`)
  and #2788 (batch memory leak); granite-docling 15–20 min/doc on CPU; the RAM-is-the-constraint framing
  every choice here still bends around

*Re-verify the pin, the licence, and the telemetry defaults at install time — this space is moving
weekly, and §4 exists because it moved twice while this document was being written.*
