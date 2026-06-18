#!/usr/bin/env bash
#
# ci/make-fixtures.sh — (re)generate the committed scanned-document test fixtures (in ci/fixtures/).
#
# The search drill (ci/search-roundtrip.sh) and the end-to-end self-test (archive-selftest.sh) both
# need a SCANNED document — an image-only PDF with NO extractable text layer — to prove that recoll's
# OCR makes such a file searchable by its CONTENTS (the family's worst case: a will that was scanned
# to paper, not typed). Rather than generate that PDF at test time (which would drag ImageMagick into
# every test run, and depends on its PDF policy), we generate it ONCE here and COMMIT the result, so
# the tests depend only on the real feature's tools (recoll + tesseract + poppler).
#
# The fixture embeds a unique marker token (FIXTURE_TOKEN below) that appears ONLY inside the scanned
# image — never in the filename or any other file — so a test that finds the token has PROVEN OCR by
# content, not a filename or born-digital-text match. The tests also assert at run time that the PDF
# still has no text layer, so the fixture can never silently regress into a typed PDF that would
# "pass" without exercising OCR at all.
#
# How it builds an image-only PDF without relying on ImageMagick's (often-disabled) PDF coder:
#   1. ImageMagick renders the document text onto a white page as a PNG (raster; no text).
#   2. ImageMagick re-encodes that to a JPEG (the JPEG coder is not policy-restricted).
#   3. A tiny pure-stdlib Python step wraps the JPEG in a one-page PDF via the /DCTDecode filter.
# The result is a standards-compliant, image-only PDF that poppler rasterizes and tesseract OCRs.
#
# Run it from anywhere as a regular user (no sudo). Needs: ImageMagick (convert/identify), python3,
# and — to self-verify the result — poppler-utils (pdftotext/pdftoppm) and tesseract.
#
#   ci/make-fixtures.sh
#
set -euo pipefail

# The marker that proves OCR. ALL letters (a digit or punctuation in the middle would make recoll
# index it as two separate terms, so a single-term query couldn't match it), uppercase so it OCRs
# back cleanly, and obviously a test token — it is not a real word and appears nowhere else.
FIXTURE_TOKEN="OCRWILLMARKER"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/fixtures/will-scanned.pdf"
mkdir -p "$here/fixtures"

c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
ok()  { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
note(){ printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
die() { printf '%s✗ %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

for t in convert identify python3; do
  command -v "$t" >/dev/null 2>&1 || die "Required tool not found: $t (install ImageMagick / python3)."
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The page text. It deliberately contains the everyday vocabulary the family will search for — will,
# testament, executor, beneficiary, estate, trust, probate, power of attorney — so the tests can prove
# those queries land, plus the unique OCR-only marker token.
note "Rendering the scanned-will page image..."
convert -size 1240x1600 xc:white -gravity north -fill black -pointsize 44 \
  -annotate +0+70 "LAST WILL AND TESTAMENT

OF JANE ARCHIVE DOE

I, Jane Archive Doe, declare this to be my
last will and testament. I appoint my son
as the executor of my estate. I name my
children as the beneficiaries.

This estate plan also establishes a family
trust and grants power of attorney. It is
to be filed for probate.

Document reference: $FIXTURE_TOKEN" \
  "$work/page.png" || die "ImageMagick could not render the page PNG."

# PNG -> JPEG (policy-free coder), then JPEG -> image-only PDF via DCTDecode (pure stdlib).
convert "$work/page.png" -quality 85 "$work/page.jpg" || die "ImageMagick could not encode the JPEG."
dims="$(identify -format '%w %h' "$work/page.jpg")" || die "could not read JPEG dimensions."
JW="${dims% *}"; JH="${dims#* }"
[[ "$JW" =~ ^[0-9]+$ && "$JH" =~ ^[0-9]+$ ]] || die "unexpected JPEG dimensions: '$dims'."

note "Wrapping the JPEG into a one-page image-only PDF (DCTDecode)..."
python3 - "$JW" "$JH" "$work/page.jpg" "$out" <<'PY'
import sys
w, h, jpg, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
img = open(jpg, "rb").read()
content = b"q %d 0 0 %d 0 0 cm /Im0 Do Q" % (w, h)
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im0 4 0 R >> >> "
    b"/MediaBox [0 0 %d %d] /Contents 5 0 R >>" % (w, h),
    b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB "
    b"/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n" % (w, h, len(img)) + img + b"\nendstream",
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
]
buf = b"%PDF-1.4\n"
offs = []
for i, o in enumerate(objs, 1):
    offs.append(len(buf))
    buf += b"%d 0 obj\n" % i + o + b"\nendobj\n"
xref = len(buf)
buf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for off in offs:
    buf += b"%010d 00000 n \n" % off
buf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(out, "wb").write(buf)
PY
[[ -s "$out" ]] || die "PDF was not written."

# Self-verify the fixture is exactly what the tests assume: an image-only PDF (no text layer) whose
# marker token IS recoverable by OCR. If either check fails, the fixture is unusable — fail loudly.
note "Verifying the fixture (no text layer; OCR recovers the token)..."
if command -v pdftotext >/dev/null 2>&1; then
  txt="$(pdftotext "$out" - 2>/dev/null | tr -d '[:space:]')"
  [[ -z "$txt" ]] || die "the PDF has a text layer ('$txt') — it would not exercise OCR. Aborting."
  ok "no extractable text layer (OCR is the only way to read it)"
else
  note "  (pdftotext not installed — skipping the no-text-layer check)"
fi
if command -v pdftoppm >/dev/null 2>&1 && command -v tesseract >/dev/null 2>&1; then
  pdftoppm -r 200 -png "$out" "$work/v" >/dev/null 2>&1 || die "poppler could not rasterize the PDF."
  if tesseract "$work/v-1.png" stdout 2>/dev/null | grep -qF "$FIXTURE_TOKEN"; then
    ok "tesseract OCR recovered the marker token ($FIXTURE_TOKEN)"
  else
    die "tesseract could NOT read the marker token back — the rendered text is not OCR-clean."
  fi
else
  note "  (poppler/tesseract not installed — skipping the OCR read-back check)"
fi

printf '\n'
ok "Wrote $out ($(wc -c < "$out") bytes)."
note "Marker token embedded (OCR-only): $FIXTURE_TOKEN"
note "Commit this file; the search tests copy it in and assert the token is found by content."
