#!/usr/bin/env bash
# ocr-bulk.sh LISTFILE [OUTDIR] — OCR a worklist of images/PDFs with tesseract into sidecar text,
# then report which ones read like estate documents (will/trust/etc). Tier-1 engine (tesseract,
# already installed; no install needed). READ-ONLY on sources; resumable; memory-guarded.
set -uo pipefail
command -v tesseract >/dev/null || { echo "ERROR: tesseract not installed"; exit 1; }

LIST="${1:-}"
OUT="${2:-/home/tom/ocr-out}"
MAXP="${MAXP:-6}"                  # OCR at most this many pages per PDF
MIN_FREE_MIB="${MIN_FREE_MIB:-2048}"

[ -s "$LIST" ] || { echo "usage: ocr-bulk.sh LISTFILE [OUTDIR]   (LISTFILE = one path per line)"; exit 1; }
case "$OUT" in
  /srv/archive|/srv/archive/*) echo "ERROR: OUTDIR must not be under /srv/archive"; exit 1;;
esac
mkdir -p "$OUT/text"

avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
[ "${avail:-0}" -ge "$MIN_FREE_MIB" ] || { echo "ERROR: low RAM (${avail:-?} MiB < ${MIN_FREE_MIB}); aborting"; exit 1; }

total="$(grep -c . "$LIST")"; i=0; did=0; skip=0
while IFS= read -r f; do
  i=$((i+1)); [ -f "$f" ] || continue
  key="$(printf '%s' "$f" | md5sum | cut -c1-16)"; txtf="$OUT/text/$key.txt"
  [ -s "$txtf" ] && { skip=$((skip+1)); continue; }   # resumable: already done
  printf '[%d/%d] %s\n' "$i" "$total" "${f##*/}"
  mt="$(file -b --mime-type "$f" 2>/dev/null)"; body=""
  case "$mt" in
    image/*)
      body="$(tesseract "$f" stdout 2>/dev/null || true)"
      if [ -z "$(printf %s "$body" | tr -d '[:space:]')" ] && command -v convert >/dev/null; then
        t="$(mktemp -d)"; convert "$f" "$t/x.png" 2>/dev/null && body="$(tesseract "$t/x.png" stdout 2>/dev/null || true)"; rm -rf "$t"
      fi ;;
    application/pdf)
      pt="$(pdftotext -l "$MAXP" "$f" - 2>/dev/null)"
      if [ -n "$(printf %s "$pt" | tr -d '[:space:]')" ]; then
        body="$pt"                                    # already has a text layer
      elif command -v pdftoppm >/dev/null; then
        t="$(mktemp -d)"; pdftoppm -r 200 -png -l "$MAXP" "$f" "$t/p" 2>/dev/null
        for img in "$t"/p*.png; do [ -f "$img" ] && body="$body"$'\n'"$(tesseract "$img" stdout 2>/dev/null || true)"; done
        rm -rf "$t"
      fi ;;
    *) continue ;;
  esac
  { printf 'SRC\t%s\n' "$f"; printf '%s\n' "$body"; } > "$txtf"
  did=$((did+1))
done < "$LIST"
echo "OCR'd $did new, skipped $skip already-done. Sidecars: $OUT/text/"

echo
echo "=== files whose OCR text reads like an ESTATE document (ranked) ==="
strong='last will|will and testament|declaration of trust|revocable trust|trust agreement|trustee|executor|small estate|letters of office|codicil|pour[- ]?over|decedent'
grep -rilE "$strong" "$OUT/text" 2>/dev/null | while IFS= read -r tf; do
  src="$(sed -n 's/^SRC\t//p' "$tf" | head -1)"
  hits="$(grep -icE 'will|trust|testament|trustee|executor|codicil|estate|hartigan|kenilworth' "$tf")"
  printf '%s\t%s\n' "$hits" "$src"
done | sort -rn | head -40 | awk -F'\t' '{printf "  [%s] %s\n", $1, $2}'
echo "(empty above = no estate-document text found in this batch)"
