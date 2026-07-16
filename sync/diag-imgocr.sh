#!/usr/bin/env bash
# diag-imgocr.sh — find WHY the scratch image-OCR test didn't OCR (empty ocrcache). Read-only except it
# re-runs the EXISTING scratch index (~/recoll-ocrtest) with verbose logging. Never touches /srv/archive.
set -uo pipefail
TESTROOT="${TESTROOT:-/home/tom/recoll-ocrtest}"
CONF="$TESTROOT/conf"; CORPUS="$TESTROOT/corpus"
sep(){ printf '\n========== %s ==========\n' "$1"; }

sep "RECOLL VERSION  (standalone-image OCR needs >= 1.43.3)"
recollindex --version 2>&1 | head -3 || true
recoll --version 2>&1 | head -1 || true
{ apt-cache policy recoll 2>/dev/null | grep -iE 'installed|candidate'; } || true
dpkg -l 2>/dev/null | awk 'tolower($2) ~ /recoll/ {print $2, $3}' || true
snap list 2>/dev/null | grep -i recoll || true
# fallbacks for source/snap/pip installs (recollindex is a compiled binary): pull the version string out
command -v recollindex >/dev/null 2>&1 && strings "$(command -v recollindex)" 2>/dev/null | grep -aoiE 'recoll[ -]?[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -3
python3 -c 'import recoll; print("python recoll module:", getattr(recoll,"version","?"))' 2>/dev/null || true

sep "DOES rclimg.py ACTUALLY DO OCR?  (grep the handler source)"
for f in /usr/share/recoll/filters/rclimg.py /usr/share/recoll/filters/rclimgp.py; do
  if [ -f "$f" ]; then echo "-- $f --"; grep -niE 'ocr|imgocr|tesseract|rclocr|runOcr' "$f" | head -12 || echo "   (no OCR-related lines — this is a TAG-ONLY handler)"; fi
done

sep "SYSTEM mimeconf: how images are handled by default"
sysmc=""
for d in /usr/share/recoll/examples /usr/share/recoll /etc/recoll; do [ -f "$d/mimeconf" ] && { sysmc="$d/mimeconf"; break; }; done
echo "system mimeconf: ${sysmc:-NOT FOUND}"
[ -n "$sysmc" ] && grep -niE '^[[:space:]]*image/(tiff|png|gif|jpeg)[[:space:]]*=' "$sysmc"
echo "-- our overlay ($CONF/mimeconf) --"; cat "$CONF/mimeconf" 2>/dev/null || echo "(none)"

sep "RE-INDEX THE SCRATCH CORPUS WITH VERBOSE LOGGING"
[ -d "$CORPUS" ] || { echo "no scratch corpus at $CORPUS — run test-imgocr.sh first"; exit 1; }
ls -la "$CORPUS"
LOG="$TESTROOT/index.log"
# bump logging to debug; keep imgocr + overlay intact
{ grep -vE '^[[:space:]]*(loglevel|logfilename)[[:space:]]*=' "$CONF/recoll.conf"; printf 'loglevel = 6\nlogfilename = %s\n' "$LOG"; } > "$CONF/recoll.conf.new" \
  && mv "$CONF/recoll.conf.new" "$CONF/recoll.conf"
echo "recoll.conf now:"; sed 's/^/    /' "$CONF/recoll.conf"
: > "$LOG"
recollindex -c "$CONF" -z >/dev/null 2>&1 || echo "(recollindex returned nonzero)"
echo "-- log lines about the image / OCR / handler / errors --"
grep -niE 'rclimg|imgocr|ocr|tesseract|\.png|\.tiff|\.jpg|missing|no handler|no filter|excluded|error|fail' "$LOG" 2>/dev/null | head -50 \
  || echo "(nothing matched in log)"

sep "WHAT recoll STORED FOR THE SCAN IMAGE"
echo "-- query its filename token 'scan' (shows mime + any OCR'd abstract) --"
recollq -c "$CONF" -A 'filename:scan*' 2>/dev/null | head -25
echo "ocrcache:"; ls -la "$CONF/ocrcache" 2>/dev/null || echo "(absent/empty — OCR never ran)"

echo; echo "diag done — paste the whole block back."
