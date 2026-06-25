#!/usr/bin/env bash
# ocr-bulk.sh LISTFILE [OUTDIR] — SAFE parallel bulk OCR (tesseract) -> sidecar text + estate-doc report.
# Stability first: bounded workers, nice + ionice so OCR yields CPU/IO to the family services; a memory
# floor; atomic + resumable sidecars (via ocr-one.sh). READ-ONLY on sources; writes only under OUTDIR
# (default /home/tom/ocr-out on the NVMe; refuses an OUTDIR under /srv/archive).
set -uo pipefail
command -v tesseract >/dev/null || { echo "ERROR: tesseract not installed"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LIST="${1:-}"; OUT="${2:-/home/tom/ocr-out}"
MAXP="${MAXP:-6}"
MIN_FREE_MIB="${MIN_FREE_MIB:-2048}"
ncpu="$(nproc 2>/dev/null || echo 4)"
maxj=$(( ncpu > 2 ? ncpu - 2 : 1 ))               # always leave >=2 cores for the family services
JOBS="${JOBS:-4}"; [ "$JOBS" -gt "$maxj" ] && JOBS="$maxj"; [ "$JOBS" -lt 1 ] && JOBS=1

[ -s "$LIST" ] || { echo "usage: ocr-bulk.sh LISTFILE [OUTDIR]   (LISTFILE = one path per line)"; exit 1; }
case "$OUT" in /srv/archive|/srv/archive/*) echo "ERROR: OUTDIR must not be under /srv/archive"; exit 1;; esac
[ -f "$HERE/ocr-one.sh" ] || { echo "ERROR: missing $HERE/ocr-one.sh (must sit next to this script)"; exit 1; }
mkdir -p "$OUT/text"

avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
[ "${avail:-0}" -ge "$MIN_FREE_MIB" ] || { echo "ERROR: low RAM (${avail:-?} MiB < ${MIN_FREE_MIB}); aborting"; exit 1; }

# Low priority so OCR uses only SPARE capacity: nice (CPU) + ionice best-effort-lowest (IO),
# both inherited by every worker. ionice -c2 -n7 is always permitted for one's own processes.
PRIO=(nice -n 19); command -v ionice >/dev/null 2>&1 && PRIO=(nice -n 19 ionice -c2 -n7)

total="$(grep -c . "$LIST")"
echo "OCR: $total files | $JOBS workers (of $ncpu cpus; >=2 reserved) | ${PRIO[*]} | resumable"
echo "Ctrl-C to stop, re-run to resume. Sidecars: $OUT/text/"

# NUL-delimited (handles spaces); one ocr-one.sh per file, $JOBS at a time, all at low priority.
tr '\n' '\0' < "$LIST" | "${PRIO[@]}" xargs -0 -P "$JOBS" -I {} bash "$HERE/ocr-one.sh" {} "$OUT" "$MAXP"

echo; echo "OCR pass done. Sidecars: $(find "$OUT/text" -name '*.txt' 2>/dev/null | wc -l) total"
echo
echo "=== files whose OCR text reads like an ESTATE document (ranked, deduped) ==="
TAB="$(printf '\t')"
grep -rilE 'last will|declaration of trust|revocable trust|trust agreement|small estate|codicil|letters of office|testament|being of sound mind' "$OUT/text" 2>/dev/null \
| while IFS= read -r tf; do
    h="$(sed '1d' "$tf" | md5sum | cut -c1-12)"
    n="$(grep -icE 'will|trust|testament|trustee|executor|estate|hartigan|kenilworth|codicil|bequeath|devise|grantor|settlor' "$tf")"
    printf '%s%s%s%s%s\n' "$n" "$TAB" "$h" "$TAB" "$(sed -n 's/^SRC\t//p' "$tf" | head -1)"
  done | sort -rn | awk -F"$TAB" '!seen[$2]++' | head -40 | awk -F"$TAB" '{printf "  [%s] %s\n", $1, $3}'
echo "(empty = none found yet)"
