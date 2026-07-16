#!/usr/bin/env bash
# ocr-one.sh FILE OUTDIR [MAXP] — OCR exactly ONE file into a sidecar text file (idempotent).
# Invoked by ocr-bulk.sh via xargs -P. READ-ONLY on FILE. Atomic write so a mid-run kill can't
# leave a partial sidecar (resumability stays correct). Inherits nice/ionice from the parent.
set -uo pipefail
f="${1:-}"; OUT="${2:-}"; MAXP="${3:-6}"
[ -n "$f" ] && [ -n "$OUT" ] || exit 0
[ -f "$f" ] || exit 0
key="$(printf '%s' "$f" | md5sum | cut -c1-16)"; txtf="$OUT/text/$key.txt"
[ -s "$txtf" ] && exit 0                      # resumable: already done

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
      body="$pt"
    elif command -v pdftoppm >/dev/null; then
      t="$(mktemp -d)"; pdftoppm -r 200 -png -l "$MAXP" "$f" "$t/p" 2>/dev/null
      for img in "$t"/p*.png; do [ -f "$img" ] && body="$body"$'\n'"$(tesseract "$img" stdout 2>/dev/null || true)"; done
      rm -rf "$t"
    fi ;;
  *) exit 0 ;;
esac
tmpf="$(mktemp)"; { printf 'SRC\t%s\n' "$f"; printf '%s\n' "$body"; } > "$tmpf"
mv -f "$tmpf" "$txtf"                          # atomic publish
printf '%s\n' "${f##*/}"                       # one atomic line = liveness (won't garble under -P)
