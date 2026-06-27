#!/usr/bin/env bash
# test-imgocr.sh — prove recoll image-OCR on a THROWAWAY scratch index BEFORE touching production.
# Verifies three things this build of recoll must do for the plan to be safe:
#   (1) scan-like images (tiff/png) get OCR'd and become searchable,
#   (2) jpeg is NOT OCR'd (our mimeconf scoping actually holds),
#   (3) normal, non-image and real-PDF indexing still work with our mimeconf overlay present.
# Writes ONLY under $TESTROOT (NVMe, never the archive). The real index is untouched. Re-runnable.
set -uo pipefail
TESTROOT="${TESTROOT:-/home/tom/recoll-ocrtest}"
case "$TESTROOT" in /srv/archive|/srv/archive/*) echo "ERROR: keep TESTROOT off the archive"; exit 1;; esac
CONF="$TESTROOT/conf"; CORPUS="$TESTROOT/corpus"
for c in recollindex recollq tesseract convert; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $c"; exit 1; }
done
[ -f /usr/share/recoll/filters/rclimg.py ] || { echo "ERROR: rclimg.py missing — image OCR unsupported"; exit 1; }

rm -rf "$TESTROOT"; mkdir -p "$CONF" "$CORPUS"

# OCR-robust coined tokens (caps only; no I/L/O/0/1; no shared stems) so OCR reads them cleanly and
# recoll's stemmer can't cross-match them.
SCANTOK=ZZSCANTAG     # rendered into tiff + png  -> MUST be found (image OCR works)
CAMTOK=ZZCAMTAG       # rendered into jpg         -> MUST NOT be found (jpeg deliberately unmapped)
TEXTTOK=ZZTEXTTAG     # written into a .txt       -> MUST be found (non-image indexing still works)

mk_img(){ convert -size 1800x320 xc:white -gravity center -pointsize 96 -fill black -annotate 0 "$2" "$1" 2>/dev/null; }
mk_img "$CORPUS/scan.tiff" "$SCANTOK"
mk_img "$CORPUS/scan.png"  "$SCANTOK"
mk_img "$CORPUS/photo.jpg" "$CAMTOK"
printf 'plain text document %s\n' "$TEXTTOK" > "$CORPUS/note.txt"

# Best-effort: copy a REAL text-layer PDF from the archive so we also prove external (non-image)
# filters still load under our overlay. Search a word we know is inside it. Skips if none found.
realword=""
if command -v pdftotext >/dev/null 2>&1 && command -v plocate >/dev/null 2>&1; then
  while IFS= read -r p; do
    [ -f "$p" ] || continue
    w="$(pdftotext -l 3 "$p" - 2>/dev/null | grep -oE '[A-Za-z]{8,}' | head -1)"
    if [ -n "$w" ]; then cp -f "$p" "$CORPUS/real.pdf" 2>/dev/null && realword="$w"; break; fi
  done < <(plocate -d /srv/archive/.plocate.db -i --regex '\.pdf$' 2>/dev/null | head -60)
fi

# Scratch config: imgocr ON, scan-like types mapped, jpeg deliberately NOT mapped.
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

echo "indexing scratch corpus (OCR runs now; a few seconds)..."
recollindex -c "$CONF" -z >/dev/null 2>&1 || { echo "ERROR: recollindex failed"; exit 1; }

hits(){ recollq -c "$CONF" "$1" 2>/dev/null | grep -cE '\[file://' ; }
pass=0; fail=0
check(){ # desc  yes|no  token
  local d="$1" want="$2" tok="$3" n; n="$(hits "$tok")"
  if { [ "$want" = yes ] && [ "$n" -gt 0 ]; } || { [ "$want" = no ] && [ "$n" -eq 0 ]; }; then
    printf 'PASS  %-46s (hits=%s)\n' "$d" "$n"; pass=$((pass+1))
  else
    printf 'FAIL  %-46s (hits=%s, expected %s)\n' "$d" "$n" "$([ "$want" = yes ] && echo '>0' || echo '0')"; fail=$((fail+1))
  fi
}

echo; echo "=== assertions ==="
check "scan-like image OCR'd & searchable" yes "$SCANTOK"
check "jpeg NOT OCR'd (scope holds)"        no "$CAMTOK"
check "non-image (.txt) still indexed"     yes "$TEXTTOK"
if [ -n "$realword" ]; then check "real PDF still indexed under overlay" yes "$realword"
else echo "SKIP  no text-layer PDF found to test external filters"; fi

echo; echo "ocrcache (proof OCR ran & is cached):"; ls -la "$CONF/ocrcache" 2>/dev/null | sed -n '1,8p'
echo; echo "summary: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then echo "OK — image OCR works, scoping holds, nothing else broke. Safe to deploy to production."
else echo "DO NOT deploy — investigate the FAIL line(s) above first."; fi
exit "$fail"
