#!/usr/bin/env bash
# diag-imgocr2.sh — pinpoint why rclimg.py produced no OCR ("send failed" in the log). Read-only;
# re-runs ONLY the scratch index (~/recoll-ocrtest). Never touches /srv/archive.
set -uo pipefail
TESTROOT="${TESTROOT:-/home/tom/recoll-ocrtest}"; CONF="$TESTROOT/conf"; CORPUS="$TESTROOT/corpus"
sep(){ printf '\n========== %s ==========\n' "$1"; }

sep "FILTER FILES (is there a plain 'rclimg' vs 'rclimg.py'?)"
ls -la /usr/share/recoll/filters/rclimg* /usr/share/recoll/filters/rclocr* 2>/dev/null

sep "PYTHON DEPS the image handler needs"
python3 -c 'import piexif; print("piexif OK:", getattr(piexif,"VERSION","?"))' 2>&1 | head -5
python3 -c 'import PIL, sys; print("Pillow OK:", PIL.__version__)' 2>&1 | head -3
echo "python3: $(command -v python3)  ($(python3 --version 2>&1))"

sep "rclimg.py — imports + OCR trigger (source)"
sed -n '1,30p;104,150p' /usr/share/recoll/filters/rclimg.py 2>/dev/null

sep "CAN recoll read imgocr from our scratch conf? (replicates the filter's own lookup)"
RECOLL_CONFDIR="$CONF" python3 - "$CONF" <<'PY' 2>&1 | head -20
import os, sys
os.environ.setdefault("RECOLL_CONFDIR", sys.argv[1])
try:
    from recoll import rclconfig
    try: c = rclconfig.RclConfig(sys.argv[1])
    except Exception: c = rclconfig.RclConfig()
    for k in ("imgocr","ocrprogs","ocrcachedir","tesseractlang"):
        try: print(k, "=", repr(c.getConfParam(k)))
        except Exception as e: print(k, "lookup error:", e)
except Exception as e:
    print("rclconfig import/use error:", e)
PY

sep "RE-INDEX SCRATCH WITH FILTER STDERR VISIBLE (look for a python Traceback)"
[ -d "$CORPUS" ] || { echo "no scratch corpus; run test-imgocr.sh first"; exit 1; }
ERRLOG="$TESTROOT/index.stderr"
recollindex -c "$CONF" -z >/dev/null 2>"$ERRLOG" || echo "(recollindex nonzero exit)"
grep -niE 'traceback|importerror|modulenotfound|no module|piexif|exception|error|rclimg|rclocr|ocr' "$ERRLOG" | head -40 \
  || echo "(nothing notable in filter stderr)"

sep "RESULT after re-run"
echo "ocrcache:"; ls -la "$CONF/ocrcache" 2>/dev/null || echo "(absent/empty — OCR still not running)"
recollq -c "$CONF" -A 'filename:scan*' 2>/dev/null | head -15

echo; echo "diag2 done — paste the whole block back."
