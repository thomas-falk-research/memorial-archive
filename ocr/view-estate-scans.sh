#!/usr/bin/env bash
# view-estate-scans.sh [ID ...] — render scanned estate attachments to high-res, HUMAN-VIEWABLE
# images so you can READ them with your own eyes when OCR comes back garbled.
#   - PDFs        -> one PNG per page at $DPI (default 300)
#   - GIF/JPG/TIF -> copied as-is (already viewable)
# READ-ONLY on sources. Writes ONLY under $VIEWDIR (NVMe). Refuses a $VIEWDIR under /srv/archive.
# Default IDs are the two prime-suspect estate scans (death cert + valuation letter).
set -uo pipefail

VIEWDIR="${VIEWDIR:-/home/tom/estate-view}"
DPI="${DPI:-300}"
PAGES="${PAGES:-40}"   # max pages per PDF to render (raise if a document is longer)

case "$VIEWDIR" in
  /srv/archive|/srv/archive/*) echo "ERROR: VIEWDIR must not be under /srv/archive"; exit 1;;
esac
command -v archive-find >/dev/null || { echo "ERROR: archive-find not on PATH"; exit 1; }
command -v pdftoppm    >/dev/null || { echo "ERROR: pdftoppm (poppler-utils) not installed"; exit 1; }

ids=("$@"); [ "${#ids[@]}" -gt 0 ] || ids=(148044612 148046140)
mkdir -p "$VIEWDIR" || { echo "ERROR: cannot create $VIEWDIR"; exit 1; }

for id in "${ids[@]}"; do
  echo "===== $id ====="
  # every matching source (across snapshots), unique by path
  archive-find "$id" 2>/dev/null | sort -u | while IFS= read -r f; do
    [ -f "$f" ] || continue
    mt="$(file -b --mime-type "$f" 2>/dev/null)"
    base="$(printf '%s' "${id}_${f##*/}" | tr ' /' '__')"
    case "$mt" in
      application/pdf)
        echo "  pdf  -> PNG@${DPI} (<=${PAGES}p)  $f"
        pdftoppm -r "$DPI" -png -l "$PAGES" "$f" "$VIEWDIR/${base%.[Pp][Dd][Ff]}" 2>/dev/null ;;
      image/*)
        echo "  img  -> copy                 $f"
        cp -f "$f" "$VIEWDIR/$base" ;;
      *)
        echo "  skip ($mt)  $f" ;;
    esac
  done
done

echo
echo "Viewable files in $VIEWDIR (largest first):"
ls -laS "$VIEWDIR" 2>/dev/null | sed -n '2,60p'
echo
echo "Now OPEN $VIEWDIR in copyparty (or any image viewer) and look at the pages."
echo "Bigger PNG = higher detail. If a document is cut off, re-run with PAGES=200."
