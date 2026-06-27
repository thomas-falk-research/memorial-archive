#!/usr/bin/env bash
# test-imgocr.sh — prove recoll image-OCR on a THROWAWAY scratch index BEFORE touching production,
# using REAL images from the archive (read-only) so NO image-generation tools are needed.
# Asserts: (1) a scan-like image (tiff/png/gif) gets OCR'd and becomes searchable; (2) a jpeg is NOT
# OCR'd (our mimeconf scoping holds); (3) a non-image (.txt) and a real PDF still index under the
# overlay. Writes ONLY under $TESTROOT (NVMe, never the archive). Real index untouched. Re-runnable.
set -uo pipefail
TESTROOT="${TESTROOT:-/home/tom/recoll-ocrtest}"
ARC="${ARC:-/srv/archive}"; PLDB="${PLDB:-$ARC/.plocate.db}"
case "$TESTROOT" in /srv/archive|/srv/archive/*) echo "ERROR: keep TESTROOT off the archive"; exit 1;; esac
for c in recollindex recollq tesseract plocate; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $c"; exit 1; }
done
[ -f /usr/share/recoll/filters/rclimg.py ] || { echo "ERROR: rclimg.py missing — image OCR unsupported"; exit 1; }
[ -r "$PLDB" ] || { echo "ERROR: plocate db not readable: $PLDB"; exit 1; }

CONF="$TESTROOT/conf"; CORPUS="$TESTROOT/corpus"
rm -rf "$TESTROOT"; mkdir -p "$CONF" "$CORPUS"

# distinctive token = the longest pure-alpha word (>=8 chars) in a text blob (stdin)
distinct(){ grep -oE '[A-Za-z]{8,}' | awk '{print length, $0}' | sort -rn | head -1 | awk '{print $2}'; }

# find a real image of TYPE (regex) under incoming/recovered that tesseract can read; print "path<TAB>word"
find_text_image(){
  local re="$1" cap="${2:-60}" n=0 p t w
  while IFS= read -r p; do
    [ -f "$p" ] || continue
    n=$((n+1)); [ "$n" -gt "$cap" ] && break
    t="$(tesseract "$p" stdout 2>/dev/null || true)"
    w="$(printf '%s' "$t" | distinct)"
    [ -n "$w" ] && { printf '%s\t%s\n' "$p" "$w"; return 0; }
  done < <(plocate -d "$PLDB" -i --regex "$re" 2>/dev/null | grep -E "^${ARC}/(incoming|recovered)/" | head -400)
}

echo "picking a real scan-like image (tiff/png/gif) with readable text (OCRs a few candidates)..."
IFS=$'\t' read -r SCANIMG SCANW < <(find_text_image '\.(tif|tiff|png|gif)$' 60) || true
[ -n "${SCANIMG:-}" ] || { echo "ERROR: couldn't find a readable scan-like image to test with"; exit 1; }
cp -f "$SCANIMG" "$CORPUS/scan.${SCANIMG##*.}"
echo "  scan: $SCANIMG"
echo "        token: $SCANW"

echo "picking a real jpeg with some text (for the negative / scope test)..."
IFS=$'\t' read -r JPGIMG JPGW < <(find_text_image '\.(jpg|jpeg)$' 60) || true
# the negative token must not also appear in the scan image's word, or the scan would satisfy the query
if [ -n "${JPGW:-}" ] && printf '%s' "$SCANW" | grep -qiwF "$JPGW"; then JPGIMG=""; JPGW=""; fi
if [ -n "${JPGIMG:-}" ]; then cp -f "$JPGIMG" "$CORPUS/photo.jpg"; echo "  jpg:  $JPGIMG"; echo "        token: $JPGW"
else echo "  (no suitable text-bearing jpeg found — the jpeg-scope assertion will be SKIPPED)"; fi

TEXTTOK=ZZTEXTTAG
printf 'plain text document %s\n' "$TEXTTOK" > "$CORPUS/note.txt"

# best-effort: a real text-layer PDF to prove external (non-image) filters still load under the overlay
realword=""
if command -v pdftotext >/dev/null 2>&1; then
  while IFS= read -r p; do
    [ -f "$p" ] || continue
    w="$(pdftotext -l 3 "$p" - 2>/dev/null | distinct)"
    [ -n "$w" ] && { cp -f "$p" "$CORPUS/real.pdf" && realword="$w"; break; }
  done < <(plocate -d "$PLDB" -i --regex '\.pdf$' 2>/dev/null | grep -E "^${ARC}/(incoming|recovered)/" | head -80)
fi

cat > "$CONF/recoll.conf" <<EOF
topdirs = $CORPUS
indexallfilenames = 1
ocrprogs = tesseract
tesseractlang = eng
pdfocr = 1
imgocr = 1
EOF
cat > "$CONF/mimeconf" <<EOF
# image-OCR overlay (scratch test)
[index]
image/tiff = execm rclimg.py
image/png = execm rclimg.py
image/gif = execm rclimg.py
EOF

echo; echo "indexing scratch corpus (OCR runs now)..."
recollindex -c "$CONF" -z >/dev/null 2>&1 || { echo "ERROR: recollindex failed"; exit 1; }

hits(){ recollq -c "$CONF" "$1" 2>/dev/null | grep -cE '\[file://' ; }
pass=0; fail=0
check(){ # desc  yes|no  token
  local d="$1" want="$2" tok="$3" n; n="$(hits "$tok")"
  if { [ "$want" = yes ] && [ "$n" -gt 0 ]; } || { [ "$want" = no ] && [ "$n" -eq 0 ]; }; then
    printf 'PASS  %-46s (hits=%s)\n' "$d" "$n"; pass=$((pass+1))
  else
    printf 'FAIL  %-46s (hits=%s, expected %s)\n' "$d" "$n" "$([ "$want" = yes ] && echo '>0' || echo 0)"; fail=$((fail+1))
  fi
}

echo; echo "=== assertions ==="
check "scan-like image OCR'd & searchable" yes "$SCANW"
if [ -n "${JPGW:-}" ]; then check "jpeg NOT OCR'd (scope holds)" no "$JPGW"; else echo "SKIP  jpeg-scope (no text-bearing jpeg found)"; fi
check "non-image (.txt) still indexed" yes "$TEXTTOK"
if [ -n "$realword" ]; then check "real PDF still indexed under overlay" yes "$realword"; else echo "SKIP  real-PDF (none with a text layer found)"; fi

echo; echo "ocrcache (proof OCR ran & is cached):"; ls -la "$CONF/ocrcache" 2>/dev/null | sed -n '1,6p'
echo; echo "summary: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then echo "OK — image OCR works, scoping holds, nothing else broke. Safe to deploy to production."
else echo "DO NOT deploy — investigate the FAIL line(s) above first."; fi
exit "$fail"
