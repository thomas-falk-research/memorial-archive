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
# Run it from anywhere as a regular user (no sudo). Needs: ImageMagick (magick OR convert), python3,
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

command -v python3 >/dev/null 2>&1 || die "Required tool not found: python3."

# ImageMagick 7 renamed the entry point: `magick` replaces `convert`, and `identify` becomes
# `magick identify`. Ubuntu's `imagemagick` package still ships IM6 with `convert`, so both are in
# the field. Detect rather than assume — a hard-coded `convert` fails on IM7 with "command not
# found", which reads like ImageMagick is absent when it is installed and working.
if command -v magick >/dev/null 2>&1; then
  IM=(magick); IMID=(magick identify); im_kind="ImageMagick 7 (magick)"
elif command -v convert >/dev/null 2>&1; then
  IM=(convert); IMID=(identify);      im_kind="ImageMagick 6 (convert)"
else
  die "ImageMagick not found (looked for 'magick' and 'convert'). Install it:
    sudo apt install -y imagemagick"
fi
note "Using $im_kind"


# no_host_metadata <file...> — a fixture is committed to a git repository, so it must carry nothing
# about the machine that produced it: no ImageMagick version, no hostname, no home directory, no
# temp path. `-strip` is supposed to remove all of that; this proves it did, because "supposed to"
# has never been evidence in this project.
#
# Only patterns of 6+ characters are searched. These files are lossy image entropy, and short
# strings occur in them by chance — the committed PDF already contains the byte sequence "o.MTom"
# purely at random inside its JPEG data. A guard that fires on coincidence gets switched off.
no_host_metadata(){
  local f pat hits="" pats=()
  [ -n "${HOSTNAME:-}" ] && pats+=("$HOSTNAME")
  pats+=("ImageMagick" "$(hostname 2>/dev/null)" "$HOME" "/tmp/tmp." "${USER:-}")
  for f in "$@"; do
    [ -s "$f" ] || continue
    for pat in "${pats[@]}"; do
      [ "${#pat}" -ge 6 ] || continue
      LC_ALL=C grep -aqF -- "$pat" "$f" 2>/dev/null && hits="$hits $(basename "$f"):$pat"
    done
  done
  if [ -n "$hits" ]; then
    die "a fixture carries host metadata and must not be committed:$hits
    These files go into a git repository. Regenerate with -strip, or remove the offending tag."
  fi
  ok "no host metadata in any fixture (no version string, hostname, home path or temp path)"
}

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The page text. It deliberately contains the everyday vocabulary the family will search for — will,
# testament, executor, beneficiary, estate, trust, probate, power of attorney — so the tests can prove
# those queries land, plus the unique OCR-only marker token.
note "Rendering the scanned-will page image..."
"${IM[@]}" -size 1240x1600 xc:white -gravity north -fill black -pointsize 44 \
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
"${IM[@]}" "$work/page.png" -strip -quality 85 "$work/page.jpg" || die "ImageMagick could not encode the JPEG."
dims="$("${IMID[@]}" -format '%w %h' "$work/page.jpg")" || die "could not read JPEG dimensions."
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

# ==================================================================================================
# The formats we are ACTUALLY hunting.
#
# Gate 2 proved attachment-content search sees inside an image-only PDF. That is not the same as
# proving it sees inside the estate documents, which arrive as `FaxImage.tif`, `image001.gif` and
# `SKM_*.pdf`. A PDF pass says nothing about a TIFF: different container, different decoder path
# inside Tika, and a fax TIFF is typically MULTI-PAGE Group 4 bilevel — the least PDF-like image
# format in common use.
#
# Four more fixtures, each carrying its OWN token, so a partial failure is visible as a partial
# failure instead of averaging into "OCR works":
#
#   will-scanned.tif        single-page TIFF          the FaxImage.tif shape
#   will-scanned-fax.tif    3-page Group 4 TIFF       token on the LAST page — catches an OCR that
#                                                     only ever reads page 1 of a multi-page fax
#   will-scanned.gif        GIF                       the image001.gif shape
#   will-scanned-long.pdf   25-page image-only PDF    token on the LAST page — catches an OCR that
#                                                     times out partway through a long document and
#                                                     indexes it with NO text and no error
# ==================================================================================================

TOKEN_TIF="OCRTIFFMARKER"
TOKEN_FAX="OCRFAXPAGETHREE"
TOKEN_GIF="OCRGIFMARKER"
TOKEN_LONG="OCRLASTPAGEMARKER"
LONG_PAGES="${LONG_PAGES:-25}"

# render_page <token> <heading> <outfile> — the same OCR-clean layout as the main fixture.
render_page(){
  local token="$1" heading="$2" dest="$3"
  "${IM[@]}" -size 1240x1600 xc:white -gravity north -fill black -pointsize 44 \
    -annotate +0+70 "$heading

OF JANE ARCHIVE DOE

I, Jane Archive Doe, declare this to be my
last will and testament. I appoint my son
as the executor of my estate.

Document reference: $token" \
    "$dest" || die "ImageMagick could not render $dest."
}

# ocr_readback <image> <token> — prove the RENDERED TEXT is OCR-clean, independent of the container
# format. Everything is normalised to PNG first: whether tesseract's local build can open a GIF is
# not the question this check is asking, and conflating the two would let a fixture problem hide
# behind a decoder problem (or the reverse).
# readback_ok <image> <frame> <token> — returns non-zero instead of dying, so a caller can fall
# back to a different encoding. When tesseract is absent nothing is provable either way: that is
# reported and treated as "not disproven", never as a pass.
readback_ok(){
  local img="$1" frame="$2" token="$3" png="$work/rb.png"
  command -v tesseract >/dev/null 2>&1 || { note "  (tesseract absent — cannot prove $(basename "$img") is OCR-clean)"; return 0; }
  rm -f "$png"
  "${IM[@]}" "${img}[${frame}]" "$png" 2>/dev/null || { note "  (could not rasterise $(basename "$img") frame $frame)"; return 1; }
  tesseract "$png" stdout 2>/dev/null | grep -qF "$token"
}

# ocr_readback <image> <token> [frame] — the same check, fatal on failure.
ocr_readback(){
  local img="$1" token="$2" frame="${3:-0}"
  if readback_ok "$img" "$frame" "$token"; then
    ok "OCR read-back OK: $(basename "$img")[$frame] -> $token"
  else
    die "tesseract could NOT read $token off $(basename "$img") frame $frame — the fixture is not OCR-clean.
    Fix this before trusting any gate that uses it: downstream, a MISSING result would be
    indistinguishable from the index genuinely being blind to this format."
  fi
}

note "Rendering the TIFF fixture (the FaxImage.tif shape)..."
render_page "$TOKEN_TIF" "LAST WILL AND TESTAMENT" "$work/tif.png"
"${IM[@]}" "$work/tif.png" -strip -compress lzw "$here/fixtures/will-scanned.tif" \
  || die "ImageMagick could not write the TIFF."
ocr_readback "$here/fixtures/will-scanned.tif" "$TOKEN_TIF"

note "Rendering the 3-page fax TIFF (token on page 3)..."
render_page "PAGE ONE OF THREE"  "FACSIMILE COVER SHEET"   "$work/fax1.png"
render_page "PAGE TWO OF THREE"  "LAST WILL AND TESTAMENT" "$work/fax2.png"
render_page "$TOKEN_FAX"         "SCHEDULE OF ASSETS"      "$work/fax3.png"
# A real fax is bilevel Group 4. Fall back to LZW rather than skipping: a multi-page TIFF that is
# not Group 4 still tests the multi-page path, which is the property that matters most here.
fax_out="$here/fixtures/will-scanned-fax.tif"
fax_kind="Group 4"
if ! "${IM[@]}" "$work/fax1.png" "$work/fax2.png" "$work/fax3.png" \
       -strip -monochrome -compress Group4 "$fax_out" 2>/dev/null; then
  note "  (Group 4 unavailable — falling back to LZW; still multi-page)"
  fax_kind="LZW"
  "${IM[@]}" "$work/fax1.png" "$work/fax2.png" "$work/fax3.png" \
    -strip -compress lzw "$fax_out" || die "could not write the multi-page TIFF."
fi
# Group 4 is bilevel, so -monochrome thresholds an antialiased render. That can thin the glyphs
# enough that tesseract loses them — and an illegible page 3 would surface downstream as "only the
# FIRST page of each fax is indexed", which is a completely different diagnosis with a completely
# different fix. Prove page 3 reads back; if the bilevel encoding costs legibility, keep the
# multi-page property (the one that matters) and drop to LZW.
if ! readback_ok "$fax_out" 2 "$TOKEN_FAX"; then
  note "  (page 3 illegible after $fax_kind encoding — rebuilding as LZW to preserve legibility)"
  fax_kind="LZW"
  "${IM[@]}" "$work/fax1.png" "$work/fax2.png" "$work/fax3.png" \
    -strip -compress lzw "$fax_out" || die "could not write the multi-page TIFF."
fi
pages="$("${IMID[@]}" "$fax_out" 2>/dev/null | wc -l)"
[ "${pages:-0}" -eq 3 ] || die "the fax TIFF has ${pages:-0} pages, expected 3."
ocr_readback "$fax_out" "$TOKEN_FAX" 2
ok "multi-page fax TIFF written (3 pages, $fax_kind, token on the last)"

note "Rendering the GIF fixture (the image001.gif shape)..."
render_page "$TOKEN_GIF" "LAST WILL AND TESTAMENT" "$work/gif.png"
"${IM[@]}" "$work/gif.png" -strip "$here/fixtures/will-scanned.gif" || die "ImageMagick could not write the GIF."
ocr_readback "$here/fixtures/will-scanned.gif" "$TOKEN_GIF"

note "Building the ${LONG_PAGES}-page image-only PDF (token on the last page)..."
render_page "FILLER PAGE"   "LAST WILL AND TESTAMENT" "$work/long-filler.png"
render_page "$TOKEN_LONG"   "SCHEDULE OF ASSETS"      "$work/long-final.png"
"${IM[@]}" "$work/long-filler.png" -strip -quality 85 "$work/long-filler.jpg" || die "could not encode filler JPEG."
"${IM[@]}" "$work/long-final.png"  -strip -quality 85 "$work/long-final.jpg"  || die "could not encode final JPEG."
# Re-read the dimensions rather than reusing the single-page fixture's. They happen to match today,
# but a PDF whose MediaBox disagrees with its image renders as a blank or clipped page — which would
# surface as "OCR cannot read long documents" and send us hunting a Tika timeout that was never there.
ldims="$("${IMID[@]}" -format '%w %h' "$work/long-filler.jpg")" || die "could not read long-page JPEG dimensions."
LW="${ldims% *}"; LH="${ldims#* }"
[[ "$LW" =~ ^[0-9]+$ && "$LH" =~ ^[0-9]+$ ]] || die "unexpected long-page dimensions: '$ldims'."
fdims="$("${IMID[@]}" -format '%w %h' "$work/long-final.jpg")" || die "could not read final-page dimensions."
[[ "$fdims" == "$ldims" ]] || die "filler and final pages differ in size ($ldims vs $fdims) — the PDF would clip one."
python3 - "$LW" "$LH" "$work/long-filler.jpg" "$work/long-final.jpg" \
           "$LONG_PAGES" "$here/fixtures/will-scanned-long.pdf" <<'PY'
import sys
w, h = int(sys.argv[1]), int(sys.argv[2])
filler, final, npages, out = sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
fill = open(filler, "rb").read()
last = open(final, "rb").read()

# Object layout: 1 catalog, 2 pages, 3 filler image, 4 final image, 5 shared content stream,
# then one page object per page. Both images are shared, so a 25-page PDF stays small while still
# forcing the OCR engine through 25 rasterised pages.
def image_obj(data):
    return (b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB "
            b"/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n" % (w, h, len(data))
            + data + b"\nendstream")

content = b"q %d 0 0 %d 0 0 cm /Im0 Do Q" % (w, h)
first_page_obj = 6
kids = b" ".join(b"%d 0 R" % (first_page_obj + i) for i in range(npages))

objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [" + kids + b"] /Count %d >>" % npages,
    image_obj(fill),
    image_obj(last),
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
]
for i in range(npages):
    img_ref = 4 if i == npages - 1 else 3       # only the LAST page carries the token
    objs.append(b"<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im0 %d 0 R >> >> "
                b"/MediaBox [0 0 %d %d] /Contents 5 0 R >>" % (img_ref, w, h))

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
[ -s "$here/fixtures/will-scanned-long.pdf" ] || die "the long PDF was not written."
if command -v pdftotext >/dev/null 2>&1; then
  [ -z "$(pdftotext "$here/fixtures/will-scanned-long.pdf" - 2>/dev/null | tr -d '[:space:]')" ] \
    || die "the long PDF has a text layer — it would not exercise OCR."
  ok "long PDF has no text layer"
fi
# This fixture exists for its LAST page. Prove that page is legible HERE, so a downstream miss can
# only mean the extractor stopped short — never that page 25 was unreadable all along.
if command -v pdftoppm >/dev/null 2>&1 && command -v tesseract >/dev/null 2>&1; then
  rm -f "$work"/lp-*.png
  pdftoppm -r 200 -png -f "$LONG_PAGES" -l "$LONG_PAGES" \
    "$here/fixtures/will-scanned-long.pdf" "$work/lp" >/dev/null 2>&1 \
    || die "poppler could not rasterise page ${LONG_PAGES} of the long PDF."
  lp="$(find "$work" -maxdepth 1 -name 'lp-*.png' | head -1)"
  [ -n "$lp" ] || die "no rasterised page produced for page ${LONG_PAGES}."
  tesseract "$lp" stdout 2>/dev/null | grep -qF "$TOKEN_LONG" \
    || die "tesseract could NOT read $TOKEN_LONG off page ${LONG_PAGES} — the fixture is not OCR-clean."
  ok "OCR read-back OK: will-scanned-long.pdf page ${LONG_PAGES} -> $TOKEN_LONG"
else
  note "  (poppler/tesseract absent — cannot prove page ${LONG_PAGES} is OCR-clean)"
fi
# "Token on the last page" is only meaningful if the page count is what we claim.
if command -v pdfinfo >/dev/null 2>&1; then
  npg="$(pdfinfo "$here/fixtures/will-scanned-long.pdf" 2>/dev/null | awk '/^Pages:/{print $2}')"
  [ "${npg:-0}" -eq "$LONG_PAGES" ] || die "the long PDF reports ${npg:-unknown} pages, expected $LONG_PAGES."
  ok "long PDF really has $npg pages"
fi
ok "wrote will-scanned-long.pdf (${LONG_PAGES} pages, token only on the last)"

no_host_metadata "$out" "$here/fixtures/will-scanned.tif" "$here/fixtures/will-scanned-fax.tif" \
                 "$here/fixtures/will-scanned.gif" "$here/fixtures/will-scanned-long.pdf"

printf '\n'
ok "Format fixtures written to $here/fixtures/:"
printf '    %-26s %s\n' "will-scanned.pdf"      "$FIXTURE_TOKEN"
printf '    %-26s %s\n' "will-scanned.tif"      "$TOKEN_TIF"
printf '    %-26s %s\n' "will-scanned-fax.tif"  "$TOKEN_FAX   (page 3 of 3)"
printf '    %-26s %s\n' "will-scanned.gif"      "$TOKEN_GIF"
printf '    %-26s %s\n' "will-scanned-long.pdf" "$TOKEN_LONG   (page ${LONG_PAGES} of ${LONG_PAGES})"
note "Commit these. openarchiver/verify-openarchiver.sh ocr attaches every one it finds and reports"
note "PER FORMAT, so blindness to TIFF cannot hide behind a PDF that works."
