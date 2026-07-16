#!/usr/bin/env python3
"""parse_one.py SRC.pdf OUT.json  —  convert ONE PDF with Docling, write a small JSON record.

Run once per file (the bash orchestrator wraps each call in an OS-level `timeout`), so a hung or
pathological PDF is killed by the parent and the run continues — Docling's own `document_timeout`
is unreliable (it only checks between batches). Reads SRC read-only; writes only OUT.

Timings are split into load_secs (import + model init) vs convert_secs (the actual conversion) so
the pilot can report HONEST per-page throughput despite models reloading on each invocation.

VERIFY-AT-INSTALL: Docling's advanced-options import paths and option names shift between releases.
If the advanced imports below fail, the basic DocumentConverter() fallback still works (default
backend, default OCR), and we pin the working API after a known-good install.
"""
import json
import sys
import time


def build_converter():
    """Return a DocumentConverter using the lighter pypdfium2 backend with OCR on, if available."""
    from docling.document_converter import DocumentConverter
    try:
        from docling.document_converter import PdfFormatOption
        from docling.datamodel.base_models import InputFormat
        from docling.datamodel.pipeline_options import PdfPipelineOptions
        opts = PdfPipelineOptions()
        opts.do_ocr = True             # scanned subset -> OCR is the whole point
        opts.do_table_structure = False  # keep the pilot light
        try:
            from docling.backend.pypdfium2_backend import PyPdfiumDocumentBackend
            pdf_opt = PdfFormatOption(pipeline_options=opts, backend=PyPdfiumDocumentBackend)
        except Exception:
            pdf_opt = PdfFormatOption(pipeline_options=opts)  # default backend
        return DocumentConverter(format_options={InputFormat.PDF: pdf_opt})
    except Exception:
        return DocumentConverter()  # fully default fallback


def main():
    if len(sys.argv) != 3:
        print("usage: parse_one.py SRC.pdf OUT.json", file=sys.stderr)
        return 2
    src, out = sys.argv[1], sys.argv[2]

    t0 = time.time()
    conv = build_converter()
    t_load = time.time()
    doc = conv.convert(src).document
    t_conv = time.time()

    text = doc.export_to_markdown()
    pages = len(getattr(doc, "pages", []) or [])
    rec = {
        "path": src,
        "pages": pages,
        "chars": len(text),
        "load_secs": round(t_load - t0, 2),
        "convert_secs": round(t_conv - t_load, 2),
        "text": text,
    }
    with open(out, "w") as fh:
        json.dump(rec, fh)
    # one-line summary the orchestrator greps for timing stats
    print(f"OK convert_secs={rec['convert_secs']} pages={pages} chars={len(text)} load_secs={rec['load_secs']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
