#!/usr/bin/env bash
# rag-pilot/probe-extractor-capability.sh — what can the pinned extractor actually DO on this box?
#
# Runs only AFTER verify-xberg-offline.sh returns PROVEN. It reuses that script's venv, so there is
# nothing new to install. Four questions, in the order they matter:
#
#   formats   Does this build read PST / MSG / EML / TIFF? -> decides whether the mailbox phase needs
#             the xberg v5 release candidate instead of the pinned v4 (the Phase-2 fork in the road).
#   ocr       Does the OCR path actually produce text from a REAL scan? (the caveat the egress gate
#             explicitly did not cover — it only exercised text/eml/csv/pdf)
#   bench     Real seconds/file and PEAK RSS over a sample of real scans — the #1 unmeasured number
#             in the whole RAG assessment.
#   pst       Point it at a mailbox and count what it finds, guarded (this is the 1.67 GB one).
#
# SAFETY
#   * Archive sources are opened READ-ONLY. Nothing is ever written under /srv/archive.
#   * All output goes under $VERIFY_HOME/capability (NVMe).
#   * A memory floor aborts before starting rather than risk swapping Immich/copyparty.
#   * Every extraction runs in its own process under an OS-level timeout, so one pathological file
#     cannot wedge the probe.
#   * --netns re-runs inside a root-created empty network namespace (extraction still unprivileged).
#     Egress was already PROVEN unnecessary; this is free insurance now that REAL family documents
#     are involved. Recommended for anything touching the mailbox.
#
# Usage:
#   bash probe-extractor-capability.sh formats
#   bash probe-extractor-capability.sh ocr /srv/archive/recovered/<...>/FaxImage.tif
#   bash probe-extractor-capability.sh bench /srv/archive/recovered/<dir> [N]
#   bash probe-extractor-capability.sh pst "/srv/archive/.../Outlook MKH.pst" [--netns]
#
set -uo pipefail

RAG_HOME="${RAG_HOME:-/home/$(id -un)/rag-pilot}"
VERIFY_HOME="${VERIFY_HOME:-$RAG_HOME/xberg-verify}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
OUT="$VERIFY_HOME/capability"
VENV="$VERIFY_HOME/venv"; PY="$VENV/bin/python"
DOC_TIMEOUT="${DOC_TIMEOUT:-300}"        # OS-level wall-clock kill per file
PST_TIMEOUT="${PST_TIMEOUT:-1800}"       # a 1.67 GB mailbox gets longer
MIN_FREE_MIB="${MIN_FREE_MIB:-3072}"     # refuse to start below this MemAvailable
SAMPLE_N="${SAMPLE_N:-20}"

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '%sOK%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '%sWARN%s %s\n' "$c_y" "$c_0" "$*" >&2; }
err(){ printf '%sERROR%s %s\n' "$c_r" "$c_0" "$*" >&2; }
die(){ err "$*"; exit 1; }

NETNS=0; ARGS=()
for a in "$@"; do case "$a" in --netns) NETNS=1 ;; *) ARGS+=("$a") ;; esac; done
cmd="${ARGS[0]:-help}"

[ -x "$PY" ] || die "No venv at $VENV — run verify-xberg-offline.sh --go first (and get a PROVEN verdict)."
mkdir -p "$OUT" || die "could not create $OUT"

guard_mem(){
  local avail; avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  say "MemAvailable: ${avail:-?} MiB (floor ${MIN_FREE_MIB})"
  [ "${avail:-0}" -ge "$MIN_FREE_MIB" ] || die "Too little free RAM to start safely — not risking the family services."
}
# wrap <cmd...> — optionally inside an empty network namespace, dropped back to this user.
wrap(){
  if [ "$NETNS" = 1 ]; then
    sudo unshare -n -- setpriv --reuid "$(id -u)" --regid "$(id -g)" --clear-groups -- "$@"
  else "$@"; fi
}
# Reject a path that is not what it claims to be, before we spend minutes on it.
need_readable(){ [ -r "$1" ] || die "not readable: $1"; }

# ---- the timed, single-file extractor ----------------------------------------------------------
cat >"$OUT/extract_timed.py" <<'PYEOF'
"""extract_timed.py SRC OUT.json — extract ONE file, record text + honest timings + metadata.

Load time (import + engine init) is separated from convert time so per-file throughput is not
inflated by process startup, which the orchestrator pays once per file by design.
"""
import json, resource, sys, time
t0 = time.time()
try:
    import xberg as X
except ImportError:
    import kreuzberg as X
fn = next((getattr(X, n) for n in ("extract_file_sync", "extract_file", "extract_sync", "extract")
           if callable(getattr(X, n, None))), None)
load = time.time() - t0
if fn is None:
    sys.exit("no extraction entry point")
src, out = sys.argv[1], sys.argv[2]
rec = {"src": src, "load_secs": round(load, 2), "engine": X.__name__}
t1 = time.time()
try:
    res = fn(src)
    if hasattr(res, "__await__"):
        import asyncio; res = asyncio.run(res)
    text = getattr(res, "content", None) or getattr(res, "text", None) or ""
    meta = getattr(res, "metadata", None)
    rec["ok"] = True
    rec["chars"] = len(text)
    rec["words"] = len(text.split())
    rec["preview"] = text[:300]
    if meta is not None:
        try:
            m = dict(meta) if not isinstance(meta, dict) else meta
            for k in ("page_count", "pages", "attachments", "attachment_count"):
                if k in m:
                    rec[k] = m[k]
        except Exception:
            pass
except Exception as e:
    rec["ok"] = False
    rec["error"] = f"{type(e).__name__}: {e}"
rec["convert_secs"] = round(time.time() - t1, 2)
# ru_maxrss is the peak for THIS process, in KiB on Linux — the same figure /usr/bin/time -v
# reports, without needing the `time` package installed.
rec["peak_rss_mib"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
with open(out, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=1)
print(json.dumps({k: v for k, v in rec.items() if k != "preview"}))
PYEOF

# run_one <src> <tag> <timeout> — extract one file under an OS timeout, capturing peak RSS.
run_one(){
  local src="$1"; local tag="$2"; local tmo="$3"
  timeout -k 10 "$tmo" "$PY" "$OUT/extract_timed.py" "$src" "$OUT/$tag.json" \
    >"$OUT/$tag.out" 2>"$OUT/$tag.err"
  local rc=$?
  [ "$rc" = 124 ] && warn "TIMEOUT after ${tmo}s: $src"
  printf '%s' "$rc"
}
peak_mib(){ jget "$1" peak_rss_mib; }   # recorded in-process; no `time` package needed
jget(){ "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }

case "$cmd" in
# ------------------------------------------------------------------------------------------------
formats)
  hdr "Format support — tested EMPIRICALLY, not taken on trust"
  # An earlier version of this probe ran `kreuzberg formats`, and when that command did not exist it
  # rendered a confident table of dashes from an empty file and concluded "PST is NOT supported" —
  # a false negative on every row. A probe that manufactures answers is worse than one that errors.
  # So: generate a real sample of each format, try to extract it, and report what actually happened.
  # Three states, and "unknown" is a real state:
  #     YES      extraction ran without an unsupported-format error
  #     NO       the library rejected the format (error quoted)
  #     UNKNOWN  we could not synthesise a sample — say so, never imply "no"
  cat >"$OUT/probe_formats.py" <<'PYEOF'
import io, json, os, struct, sys, tempfile, zipfile
try:
    import xberg as X
except ImportError:
    import kreuzberg as X
fn = next((getattr(X, n) for n in ("extract_file_sync", "extract_file", "extract_sync", "extract")
           if callable(getattr(X, n, None))), None)
if fn is None:
    sys.exit("no extraction entry point")

def minimal_tiff():
    """1x1 8-bit greyscale, uncompressed — enough to exercise the image/OCR route."""
    tags = [(256, 3, 1, 1), (257, 3, 1, 1), (258, 3, 1, 8), (259, 3, 1, 1),
            (262, 3, 1, 1), (273, 4, 1, 8 + 2 + 12 * 8 + 4), (278, 3, 1, 1), (279, 4, 1, 1)]
    out = io.BytesIO()
    out.write(b"II" + struct.pack("<HI", 42, 8))
    out.write(struct.pack("<H", len(tags)))
    for tag, typ, cnt, val in tags:
        out.write(struct.pack("<HHI", tag, typ, cnt))
        out.write(struct.pack("<HH", val, 0) if typ == 3 else struct.pack("<I", val))
    out.write(struct.pack("<I", 0))
    out.write(b"\xff")
    return out.getvalue()

def minimal_docx():
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("[Content_Types].xml",
            '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" '
            'ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override '
            'PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.'
            'wordprocessingml.document.main+xml"/></Types>')
        z.writestr("_rels/.rels",
            '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
            'relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/'
            '2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr("word/document.xml",
            '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/'
            '2006/main"><w:body><w:p><w:r><w:t>SYNTHETICDOCXPAYLOAD</w:t></w:r></w:p></w:body></w:document>')
    return b.getvalue()

def minimal_zip():
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("inner.txt", "SYNTHETICZIPPAYLOAD")
    return b.getvalue()

EML = (b"From: a@example.invalid\r\nTo: b@example.invalid\r\nSubject: Synthetic\r\n"
       b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"B\"\r\n\r\n--B\r\n"
       b"Content-Type: text/plain\r\n\r\nSYNTHETICEMLBODY\r\n--B\r\n"
       b"Content-Type: text/plain; name=\"att.txt\"\r\n"
       b"Content-Disposition: attachment; filename=\"att.txt\"\r\n\r\n"
       b"SYNTHETICATTACHMENT\r\n--B--\r\n")

PDF = (b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
       b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
       b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R"
       b"/Resources<</Font<</F1 5 0 R>>>>>>endobj\n"
       b"4 0 obj<</Length 62>>stream\nBT /F1 12 Tf 20 100 Td (SYNTHETICPDFPAYLOAD) Tj ET\n"
       b"endstream endobj\n5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n"
       b"trailer<</Root 1 0 R>>\n")

SAMPLES = {
    "txt":  b"SYNTHETICTXTPAYLOAD\n",
    "csv":  b"a,b\n1,SYNTHETICCSVPAYLOAD\n",
    "html": b"<html><body>SYNTHETICHTMLPAYLOAD</body></html>",
    "eml":  EML,
    "pdf":  PDF,
    "tiff": minimal_tiff(),
    "docx": minimal_docx(),
    "zip":  minimal_zip(),
}
# Cannot be synthesised meaningfully: .msg is an OLE compound file, .pst/.ost are whole mailbox
# databases. Reported as UNKNOWN rather than guessed — `pst <real file>` is the honest test.
UNSYNTHESISABLE = ["msg", "pst", "ost", "mbox"]

results = {}
tmp = tempfile.mkdtemp()
for ext, data in SAMPLES.items():
    path = os.path.join(tmp, f"sample.{ext}")
    with open(path, "wb") as f:
        f.write(data)
    try:
        res = fn(path)
        if hasattr(res, "__await__"):
            import asyncio; res = asyncio.run(res)
        text = getattr(res, "content", None) or getattr(res, "text", None) or ""
        # Success WITHOUT an unsupported-format error means the format is handled, even if a 1x1
        # blank image yields no words. Text presence is reported separately.
        results[ext] = {"state": "YES", "chars": len(text), "text_found": bool(text.strip())}
    except Exception as e:
        msg = f"{type(e).__name__}: {e}"
        unsupported = any(k in msg.lower() for k in
                          ("unsupported", "not supported", "mime", "unknown format", "no extractor"))
        results[ext] = {"state": "NO" if unsupported else "ERROR", "error": msg[:200]}
    finally:
        try: os.unlink(path)
        except OSError: pass
for ext in UNSYNTHESISABLE:
    results[ext] = {"state": "UNKNOWN", "why": "cannot synthesise a valid sample"}
print(json.dumps(results, indent=1))
PYEOF
  "$PY" "$OUT/probe_formats.py" >"$OUT/formats.json" 2>"$OUT/formats.err" || {
    err "format probing failed:"; tail -10 "$OUT/formats.err" | sed 's/^/    /'; exit 1; }

  say ""
  printf '  %-8s %-9s %s\n' FORMAT STATE DETAIL
  "$PY" - "$OUT/formats.json" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
G, Y, R, Z = "\033[1;32m", "\033[1;33m", "\033[1;31m", "\033[0m"
for ext in ("txt", "csv", "html", "pdf", "eml", "tiff", "docx", "zip", "msg", "pst", "ost", "mbox"):
    d = r.get(ext, {})
    st = d.get("state", "UNKNOWN")
    col = {"YES": G, "NO": R, "ERROR": R, "UNKNOWN": Y}[st]
    if st == "YES":
        detail = f"{d['chars']} chars" + ("" if d["text_found"] else "  (no text — blank sample)")
    elif st == "UNKNOWN":
        detail = d.get("why", "")
    else:
        detail = d.get("error", "")
    print(f"  {ext:<8} {col}{st:<9}{Z} {detail}")
PYEOF

  hdr "PHASE-2 DECISION"
  eml_state="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["eml"]["state"])' "$OUT/formats.json" 2>/dev/null)"
  if [ "$eml_state" = YES ]; then
    ok "EML extraction works on this pinned, MIT, stable build."
    say "  That settles the mailbox route WITHOUT taking the v5 release candidate:"
    say "  MKH's PST is ALREADY extracted to .derived, so we feed the extracted mail — same"
    say "  messages, same attachments, no new package and no second egress gate."
    say ""
    say "  Native PST (v5) would only save re-walking a tree we have already walked. Not worth"
    say "  a release-candidate dependency and a fresh security verification for the will hunt."
  else
    warn "EML did NOT extract cleanly — that is the format the mailbox route depends on."
    say "  Check the detail above before choosing a route; do not assume the v5 rc is the answer"
    say "  until this is understood, because it may be an install problem rather than a format gap."
  fi
  say ""
  say "  Documented position (upstream docs, v4): EML and MSG are supported by a dedicated email"
  say "  extractor; PST/OST/mbox are not listed for v4 and appear on the xberg v5 line."
  say "  Raw results: $OUT/formats.json"
  ;;
# ------------------------------------------------------------------------------------------------
ocr)
  src="${ARGS[1]:-}"; [ -n "$src" ] || die "usage: $0 ocr <path-to-a-real-scan>"
  need_readable "$src"
  hdr "OCR path on a REAL scan (the case the egress gate did not cover)"
  say "  source (read-only): $src"
  say "  size: $(du -h "$src" 2>/dev/null | cut -f1)"
  guard_mem
  rc="$(wrap bash -c "$(declare -f run_one); OUT='$OUT'; PY='$PY'; run_one '$src' ocr-probe '$DOC_TIMEOUT'" 2>/dev/null)"
  [ -s "$OUT/ocr-probe.json" ] || { err "no result written"; tail -5 "$OUT/ocr-probe.err" 2>/dev/null | sed 's/^/    /'; exit 1; }
  chars="$(jget "$OUT/ocr-probe.json" chars)"; words="$(jget "$OUT/ocr-probe.json" words)"
  secs="$(jget "$OUT/ocr-probe.json" convert_secs)"; okflag="$(jget "$OUT/ocr-probe.json" ok)"
  say ""
  say "  extracted : ${chars:-0} chars / ${words:-0} words in ${secs:-?}s   (peak RSS $(peak_mib "$OUT/ocr-probe.json") MiB)"
  say "  --- first 300 chars ---"
  jget "$OUT/ocr-probe.json" preview | sed 's/^/    /'
  say "  -----------------------"
  if [ "$okflag" != "True" ]; then
    err "extraction FAILED: $(jget "$OUT/ocr-probe.json" error)"; exit 1
  elif [ "${words:-0}" -lt 5 ]; then
    warn "Almost no text came out. Either this scan is blank/graphical, or OCR did not engage."
    warn "Try another scan before concluding. If it is consistently empty, the tesseract extra"
    warn "may not be wired up in this build — that is a blocker for the whole scanned corpus."
  else
    ok "OCR produced real text from a real scan."
  fi
  ;;
# ------------------------------------------------------------------------------------------------
bench)
  dir="${ARGS[1]:-}"; n="${ARGS[2]:-$SAMPLE_N}"
  [ -n "$dir" ] || die "usage: $0 bench <dir-of-real-scans> [N]"
  [ -d "$dir" ] || die "not a directory: $dir"
  hdr "Throughput + peak RSS over $n real files (the assessment's #1 unknown)"
  guard_mem
  mapfile -t files < <(find "$dir" -type f \( -iname '*.pdf' -o -iname '*.tif' -o -iname '*.tiff' \
    -o -iname '*.png' -o -iname '*.jpg' \) -size -50M 2>/dev/null | head -"$n")
  [ "${#files[@]}" -gt 0 ] || die "no candidate files under $dir"
  say "  sampling ${#files[@]} files, one process each, ${DOC_TIMEOUT}s OS timeout"
  : >"$OUT/bench.tsv"
  i=0; fails=0
  for f in "${files[@]}"; do
    i=$((i+1))
    rc="$(wrap bash -c "$(declare -f run_one); OUT='$OUT'; PY='$PY'; run_one \"\$1\" bench-$i '$DOC_TIMEOUT'" _ "$f" 2>/dev/null)"
    if [ -s "$OUT/bench-$i.json" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(stat -c %s "$f" 2>/dev/null)" "$(jget "$OUT/bench-$i.json" convert_secs)" \
        "$(jget "$OUT/bench-$i.json" chars)" "$(peak_mib "$OUT/bench-$i.json")" "$f" >>"$OUT/bench.tsv"
    else fails=$((fails+1)); fi
    printf '\r  %d/%d' "$i" "${#files[@]}"
  done; printf '\n'
  awk -F'\t' '
    {n++; bytes+=$1; secs+=$2; chars+=$3; if($4>peak)peak=$4; if($2>slow){slow=$2; slowf=$5}}
    END{
      if(!n){print "  no successful extractions"; exit}
      printf "\n  files            : %d\n", n
      printf "  total bytes      : %.1f MiB\n", bytes/1048576
      printf "  total convert    : %.1f s\n", secs
      printf "  mean per file    : %.2f s\n", secs/n
      printf "  throughput       : %.2f MiB/s   (%.2f files/s)\n", (bytes/1048576)/(secs?secs:1), n/(secs?secs:1)
      printf "  text extracted   : %d chars\n", chars
      printf "  PEAK RSS         : %d MiB   <-- the number that sets the memory budget\n", peak
      printf "  slowest file     : %.1f s  %s\n", slow, slowf
    }' "$OUT/bench.tsv"
  if [ "$fails" -gt 0 ]; then
    warn "$fails file(s) produced no result (timeout or crash) — kept in $OUT/bench-*.err"
    first_err="$(find "$OUT" -name 'bench-*.err' -size +0 2>/dev/null | head -1)"
    [ -n "$first_err" ] && { say "  --- first failure (${first_err##*/}) ---"; tail -5 "$first_err" | sed 's/^/    /'; }
  fi
  say ""
  say "  Extrapolate before committing to a full run: mean-per-file x corpus size."
  say "  Full detail: $OUT/bench.tsv"
  ;;
# ------------------------------------------------------------------------------------------------
pst)
  src="${ARGS[1]:-}"; [ -n "$src" ] || die "usage: $0 pst <path-to-mailbox> [--netns]"
  need_readable "$src"
  hdr "Mailbox extraction (guarded)"
  say "  source (read-only): $src"
  say "  size: $(du -h "$src" 2>/dev/null | cut -f1)"
  [ "$NETNS" = 1 ] || warn "running WITHOUT a network namespace — consider --netns for real family data"
  guard_mem
  say "  timeout ${PST_TIMEOUT}s; peak RSS captured. This may take a long while — leave it alone."
  rc="$(wrap bash -c "$(declare -f run_one); OUT='$OUT'; PY='$PY'; run_one \"\$1\" pst-probe '$PST_TIMEOUT'" _ "$src" 2>/dev/null)"
  if [ ! -s "$OUT/pst-probe.json" ]; then
    err "no result written (rc=$rc)"; tail -10 "$OUT/pst-probe.err" 2>/dev/null | sed 's/^/    /'
    say "  If this says the format is unsupported, that is the §4 answer: the mailbox phase needs xberg v5."
    exit 1
  fi
  say ""
  say "  ok        : $(jget "$OUT/pst-probe.json" ok)"
  say "  chars     : $(jget "$OUT/pst-probe.json" chars)"
  say "  words     : $(jget "$OUT/pst-probe.json" words)"
  say "  seconds   : $(jget "$OUT/pst-probe.json" convert_secs)"
  say "  peak RSS  : $(peak_mib "$OUT/pst-probe.json") MiB"
  for k in page_count pages attachments attachment_count; do
    v="$(jget "$OUT/pst-probe.json" "$k")"; [ -n "$v" ] && say "  $k: $v"
  done
  err_txt="$(jget "$OUT/pst-probe.json" error)"
  if [ -n "$err_txt" ]; then
    err "error: $err_txt"
    case "$err_txt" in
      *[Uu]nsupported*|*[Mm]ime*|*[Ff]ormat*|*outlook*)
        say ""
        say "  That is the §4 answer: this build cannot read the mailbox format. Two routes:"
        say "   1. Use the ALREADY-EXTRACTED mail in .derived — run '$0 formats' to confirm eml/msg,"
        say "      then bench that instead. No new package, no new egress gate."
        say "   2. Take the xberg v5 line for native PST, and RE-RUN the egress gate on it first:"
        say "        XBERG_PIN='xberg==1.0.0rc42' bash verify-xberg-offline.sh teardown --go"
        say "        XBERG_PIN='xberg==1.0.0rc42' bash verify-xberg-offline.sh --go --sudo-netns"
        say "      A different package is a different set of network behaviours; the PROVEN verdict"
        say "      from v4.10.2 does NOT carry over to it." ;;
    esac
    exit 1
  fi
  say "  --- first 300 chars ---"; jget "$OUT/pst-probe.json" preview | sed 's/^/    /'
  ok "Mailbox produced text. Cross-check the message/attachment count against the existing"
  say "  .derived PST extraction before trusting it as complete."
  ;;
# ------------------------------------------------------------------------------------------------
*)
  say "Usage: ${0##*/} <formats|ocr SRC|bench DIR [N]|pst SRC> [--netns]"
  say ""
  say "  formats           can this build read PST/MSG/EML/TIFF?  (decides the Phase-2 route)"
  say "  ocr SRC           does OCR yield real text from a real scan?"
  say "  bench DIR [N]     seconds/file + PEAK RSS over N real files"
  say "  pst SRC           point it at a mailbox, guarded by a memory floor + timeout"
  say "  --netns           run inside an empty network namespace (sudo; recommended for family data)"
  say ""
  say "Run verify-xberg-offline.sh --go --sudo-netns FIRST and get a PROVEN verdict."
  ;;
esac
