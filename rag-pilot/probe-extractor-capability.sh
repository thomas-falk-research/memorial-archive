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
VENV="$VERIFY_HOME/venv"; PY="$VENV/bin/python"; CLI="$VENV/bin/kreuzberg"
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
  hdr "Supported formats — does this build read mailboxes?"
  if [ -x "$CLI" ]; then
    wrap "$CLI" formats >"$OUT/formats.txt" 2>&1 || warn "'kreuzberg formats' returned non-zero"
    say "  (full list: $OUT/formats.txt — $(wc -l <"$OUT/formats.txt") lines)"
  else
    warn "no CLI in the venv; cannot list formats"; : >"$OUT/formats.txt"
  fi
  say ""
  printf '  %-14s %s\n' FORMAT SUPPORTED
  verdict_pst="no"
  for f in pst ost msg eml mbox tif tiff jbig2 pdf docx xlsx zip; do
    if grep -qiw -- "$f" "$OUT/formats.txt" 2>/dev/null; then
      printf '  %-14s %sYES%s\n' "$f" "$c_g" "$c_0"
      [ "$f" = pst ] && verdict_pst="yes"
    else
      printf '  %-14s %s—%s\n' "$f" "$c_y" "$c_0"
    fi
  done
  hdr "PHASE-2 DECISION"
  if [ "$verdict_pst" = yes ]; then
    ok "This build reads PST — the mailbox phase can run on the pinned, MIT, stable v4.10.2."
    say "  No need to take the xberg v5 release candidate for the will hunt."
  else
    warn "PST is NOT listed for this build."
    say "  The mailbox traversal (the reason this swap matters) needs the xberg v5 line:"
    say "      XBERG_PIN='xberg==1.0.0rc42' bash verify-xberg-offline.sh teardown --go"
    say "      XBERG_PIN='xberg==1.0.0rc42' bash verify-xberg-offline.sh --go --sudo-netns"
    say "  Re-run the egress gate on that build BEFORE any family data touches it — a different"
    say "  package is a different set of network behaviours, and the last verdict does not carry over."
    say ""
    say "  Note: our PST is ALREADY extracted to .derived, so EML/MSG support alone may be enough."
    if grep -qiw -- 'eml\|msg' "$OUT/formats.txt" 2>/dev/null; then
      ok "  eml/msg ARE supported here — the extracted-mail route works on v4 today."
    else
      warn "  eml/msg not listed either — check $OUT/formats.txt by hand."
    fi
  fi
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
