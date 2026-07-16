#!/usr/bin/env bash
# show-estate-hits.sh [OUTDIR] — read the OCR sidecars, dedup duplicate scans by OCR-content hash,
# and print the TEXT of the top estate-document candidates so we can identify the actual will & trust.
# READ-ONLY. Tunables: N=<docs to show> (default 12), LINES=<lines each> (default 25).
set -uo pipefail
OUT="${1:-/home/tom/ocr-out}"; DIR="$OUT/text"
N="${N:-12}"; LINES="${LINES:-25}"
[ -d "$DIR" ] || { echo "no sidecars at $DIR (run ocr-bulk.sh first)"; exit 1; }
TAB="$(printf '\t')"
grep -rilE 'last will|declaration of trust|revocable trust|trust agreement|small estate|codicil|letters of office|testament|being of sound mind' "$DIR" 2>/dev/null \
| while IFS= read -r tf; do
    h="$(sed '1d' "$tf" | md5sum | cut -c1-12)"
    n="$(grep -icE 'will|trust|testament|trustee|executor|estate|hartigan|kenilworth|codicil|bequeath|devise|grantor|settlor' "$tf")"
    printf '%s%s%s%s%s\n' "$n" "$TAB" "$h" "$TAB" "$tf"
  done | sort -rn | awk -F"$TAB" '!seen[$2]++' | head -"$N" \
| while IFS="$TAB" read -r n h tf; do
    src="$(sed -n 's/^SRC\t//p' "$tf" | head -1)"
    echo "================= [$n estate-terms] $src ================="
    sed '1d' "$tf" | sed '/^[[:space:]]*$/d' | head -"$LINES"
    echo
  done
