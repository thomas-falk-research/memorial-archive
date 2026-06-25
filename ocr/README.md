# ocr-sidecar — bulk OCR of the scans recoll can't read

recoll OCRs PDFs but **never** standalone images (jpg/png/gif/tif), and some scanned PDFs error out.
So scanned documents — possibly **John Sr.'s will/trust** — can be present yet invisible to search.
This tool OCRs a worklist of such files into **sidecar text**, then flags any that read like estate
documents. It is additive and reversible.

## Safety
- **READ-ONLY on sources.** Writes only under `OUTDIR` (default `/home/tom/ocr-out`) on the NVMe;
  refuses to run if `OUTDIR` is under `/srv/archive`.
- Never touches masters or the recoll index.
- **Resumable** — re-running skips files already OCR'd.
- Memory floor aborts rather than swap the family services.

## Engine tiers
- **Tier 1 — tesseract** (this script, `ocr-bulk.sh`): already installed, no install, fast. Good enough
  to *find* a will/trust by keywords even if the OCR is rough.
- **Tier 2 — RapidOCR / PaddleOCR** (planned): far better on real-world scans; CPU-fast. RapidOCR is
  pure ONNX (no telemetry); PaddleOCR needs the telemetry kill-switches (see the RAG assessment).
- **Tier 3 — dots.ocr** (planned): SOTA VLM via quantized GGUF/llama.cpp; minutes/page on CPU, so
  reserve for the hardest/highest-value pages only.

## Usage
```
# build a worklist first (one path per line), e.g. the estate-context candidates:
./ocr-bulk.sh /tmp/estate-img-candidates.txt          # OCR images (fast; includes the estate GIFs)
./ocr-bulk.sh /tmp/estate-pdf-candidates.txt          # then the scanned PDFs
# results: sidecar text in /home/tom/ocr-out/text/, plus an on-screen "looks like an estate document"
# report. Tunables: OUTDIR (arg 2), MAXP (pages/PDF), MIN_FREE_MIB.
```
Then to read a hit: find its `SRC` line (first line of each sidecar `.txt`) and open that source file.
