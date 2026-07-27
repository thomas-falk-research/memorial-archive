#!/usr/bin/env bash
# rag-pilot/verify-xberg-offline.sh — PHASE 0 GATE: prove the xberg/Kreuzberg extractor sends nothing
# off this box before a single family document is ever pointed at it.
#
# xberg advertises cloud VLM OCR (GPT-4V/Claude/Gemini), remote embedding APIs and "143+ LLM providers".
# The docs say all of that is opt-in and that Tesseract (fully local) is the default — but "the docs say"
# is not a standard this archive accepts for attorney-client files, medical records and a family's private
# correspondence. So we test the property we actually care about:
#
#     Does extraction produce IDENTICAL results with the network COMPLETELY REMOVED?
#
# If yes, the extractor provably requires no egress at runtime. The test runs only on SYNTHETIC documents
# this script generates itself — no family data is involved in the verification, by design.
#
# It also reports the installed artifact's LICENCE (the README says MIT, the PyPI alias package says
# Elastic-2.0 — see docs/RAG-EXTRACTION-XBERG-ASSESSMENT.md §4) and any telemetry/remote-backend settings
# it can find.
#
# Safety: writes ONLY under $VERIFY_HOME (NVMe, never the archive). Reads no archive file at all. Deletes
# nothing outside its own directory. DRY-RUN by default — add --go to act.
#
#   bash verify-xberg-offline.sh              # show the plan, change nothing
#   bash verify-xberg-offline.sh --go         # create the venv, install the pin, run both passes
#   XBERG_PIN=xberg==1.0.0 bash verify-xberg-offline.sh --go
#   bash verify-xberg-offline.sh teardown --go
#
set -uo pipefail

RAG_HOME="${RAG_HOME:-/home/$(id -un)/rag-pilot}"
VERIFY_HOME="${VERIFY_HOME:-$RAG_HOME/xberg-verify}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
# Pin explicitly — never float. DEFAULT IS THE CANONICAL, STABLE, MIT-LICENSED PACKAGE.
#
# TRAP (learned the hard way): `pip install xberg` does NOT get you xberg. Its only *stable* release on
# PyPI is 0.1.0, a placeholder alias; the real code ships as 1.0.0rcN pre-releases, which pip ignores
# unless you pass --pre. Installing the bare name yields a stub that would make this whole verification
# meaningless — it would "pass" without ever extracting anything. So: pin a version, always.
#
#   kreuzberg[tesseract]==4.10.2   canonical, MIT, manylinux wheel, local OCR  <- default
#   xberg==1.0.0rc42               the v5 line (pre-release; --pre is added automatically below)
XBERG_PIN="${XBERG_PIN:-kreuzberg[tesseract]==4.10.2}"

VENV="$VERIFY_HOME/venv"; PY="$VENV/bin/python"; PIP="$VENV/bin/pip"
DOCS="$VERIFY_HOME/docs"; OUT_NET="$VERIFY_HOME/out-network"; OUT_OFF="$VERIFY_HOME/out-offline"
LOGS="$VERIFY_HOME/logs"

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '%sOK%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '%sWARN%s %s\n' "$c_y" "$c_0" "$*" >&2; }
err(){ printf '%sERROR%s %s\n' "$c_r" "$c_0" "$*" >&2; }
die(){ err "$*"; exit 1; }

case "$VERIFY_HOME" in
  "$ARCHIVE_ROOT"|"$ARCHIVE_ROOT"/*) die "VERIFY_HOME ($VERIFY_HOME) must NOT be under the archive ($ARCHIVE_ROOT).";;
esac

GO=0; SUDO_NETNS=0; STRACE_ALWAYS=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --go)          GO=1 ;;
    --sudo-netns)  SUDO_NETNS=1 ;;   # allow sudo to create the empty network namespace
    --strace)      STRACE_ALWAYS=1 ;; # also run the syscall audit even if a namespace worked
    *)             ARGS+=("$a") ;;
  esac
done
cmd="${ARGS[0]:-verify}"

if [ "$cmd" = "teardown" ]; then
  say "Would delete: $VERIFY_HOME"
  [ "$GO" = 1 ] || { say "(dry-run — add --go to actually delete)"; exit 0; }
  rm -rf "$VERIFY_HOME" && ok "removed $VERIFY_HOME"; exit 0
fi

hdr "Plan"
cat <<PLAN
  sandbox            : $VERIFY_HOME      (NVMe; never the archive)
  pin to install     : $XBERG_PIN
  documents          : SYNTHETIC ONLY, generated here — no family data is used
  pass 1             : extract WITH network (models may download on first use)
  pass 2             : extract with NO NETWORK AT ALL (unshare -rn)
  verdict            : pass 2 == pass 1  =>  no runtime egress required
  also reported      : installed licence, telemetry/remote-backend settings, what was downloaded
PLAN
[ "$GO" = 1 ] || { say ""; say "(dry-run — nothing was created. Add --go to run the verification.)"; exit 0; }

command -v python3 >/dev/null 2>&1 || die "python3 is required."
mkdir -p "$DOCS" "$OUT_NET" "$OUT_OFF" "$LOGS" || die "could not create $VERIFY_HOME"

# ---- synthetic corpus (no family data) ---------------------------------------------------------
hdr "Generating synthetic test documents"
# Deliberately covers the formats that matter here: plain text, an EMAIL with an attachment (the shape
# the estate documents actually take), CSV, and a minimal hand-written PDF (no ImageMagick dependency —
# an earlier lesson in this project).
printf 'Synthetic test document.\nRatliff Northern Trust December 5 2005 small estate affidavit.\n' >"$DOCS/plain.txt"
printf 'name,amount\nsynthetic,1\n' >"$DOCS/table.csv"
cat >"$DOCS/message.eml" <<'EML'
From: sender@example.invalid
To: recipient@example.invalid
Subject: Synthetic test message with attachment
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUND"

--BOUND
Content-Type: text/plain

Synthetic body text for extraction testing.
--BOUND
Content-Type: text/plain; name="attachment.txt"
Content-Disposition: attachment; filename="attachment.txt"

Synthetic attachment payload.
--BOUND--
EML
# A minimal, valid, uncompressed one-page PDF with a text object — written literally so this script
# needs no PDF tooling to produce its own fixture.
{
  printf '%%PDF-1.4\n'
  printf '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
  printf '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
  printf '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n'
  printf '4 0 obj<</Length 60>>stream\nBT /F1 12 Tf 20 100 Td (Synthetic PDF payload) Tj ET\nendstream endobj\n'
  printf '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n'
  printf 'trailer<</Root 1 0 R>>\n'
} >"$DOCS/simple.pdf"
ok "$(find "$DOCS" -type f | wc -l) synthetic documents in $DOCS"

# ---- install (idempotent) ----------------------------------------------------------------------
hdr "Installing $XBERG_PIN into a throwaway venv"
if [ -x "$VENV/bin/xberg" ] || [ -x "$PY" ]; then
  ok "venv already present at $VENV — reusing it (re-runnable; delete with 'teardown --go')"
else
  python3 -m venv "$VENV" >>"$LOGS/install.log" 2>&1 || die "could not create the venv (need python3-venv?)"
  "$PIP" install --upgrade pip >>"$LOGS/install.log" 2>&1
  # A pre-release pin (…rcN / …aN / …bN) needs --pre, or pip silently resolves to an older stable.
  pre=""
  case "$XBERG_PIN" in *rc[0-9]*|*a[0-9]*|*b[0-9]*) pre="--pre"; say "  (pre-release pin — adding --pre)";; esac
  # shellcheck disable=SC2086  # $pre is deliberately word-split: it is either empty or exactly --pre
  "$PIP" install $pre "$XBERG_PIN" >>"$LOGS/install.log" 2>&1 \
    || die "pip install '$XBERG_PIN' failed — see $LOGS/install.log"
  ok "installed"
fi

# ---- what did we actually get? (licence + version + telemetry surface) -------------------------
hdr "Installed artifact"
"$PIP" list 2>/dev/null | grep -iE 'xberg|kreuzberg' | sed 's/^/  /'
for dist in xberg kreuzberg; do
  meta="$("$PY" - "$dist" <<'PYEOF' 2>/dev/null
import sys
try:
    from importlib.metadata import metadata, version
    m = metadata(sys.argv[1])
    print(f"  {sys.argv[1]}: version={version(sys.argv[1])} license={m.get('License') or m.get('License-Expression') or '?'}")
except Exception:
    pass
PYEOF
)"
  [ -n "$meta" ] && say "$meta"
done
say "  (README claims MIT; the PyPI alias package declared Elastic-2.0 — this is the authoritative answer)"

hdr "Telemetry / remote-backend surface (grep of the installed package)"
# Split source matches from compiled artifacts. Shared objects and SBOMs practically always contain
# these strings (onnxruntime carries platform tracing hooks it never activates on Linux), so lumping
# them together produces a scary warning that means nothing. Source matches are what deserve a read.
tel_all="$(grep -rlniE 'telemetry|analytics|posthog|sentry|mixpanel|phone_?home' "$VENV/lib" 2>/dev/null || true)"
tel_src="$(printf '%s\n' "$tel_all" | grep -vE '\.(so|so\.[0-9.]*|pyc|dylib|dll)$|/pip/|dist-info/sboms/|\.json$' | grep -v '^$' || true)"
tel_bin="$(printf '%s\n' "$tel_all" | grep -E  '\.(so|so\.[0-9.]*|pyc|dylib|dll)$|dist-info/sboms/|\.json$' | grep -v '^$' || true)"
if [ -n "$tel_src" ]; then
  warn "SOURCE files mentioning telemetry-ish names — read these before trusting the library:"
  printf '%s\n' "$tel_src" | sed 's/^/    /'
else
  ok "no telemetry/analytics identifiers in any SOURCE file of the extractor"
fi
if [ -n "$tel_bin" ]; then
  say "  (also matched in compiled/SBOM artifacts, which is normal and not evidence of anything:"
  printf '%s\n' "$tel_bin" | sed 's|.*/||; s/^/     - /' | head -6
  say "   the offline pass below is what actually settles this.)"
fi
say "  env vars in this shell that could enable a REMOTE backend (should be empty):"
env | grep -iE '^(OPENAI|ANTHROPIC|GOOGLE|GEMINI|AZURE|COHERE|MISTRAL|HF|HUGGING)' | sed 's/=.*/=<set>/' | sed 's/^/    /' \
  || true

# ---- the extraction runner ---------------------------------------------------------------------
# Prefer the PYTHON API: it is what the pilot's parse stage will actually call (parse_one.py), so it is
# the surface worth certifying. The CLI is a fallback only.
# CORRECTED: `kreuzberg extract FILE` writes to STDOUT — there is no --output-dir flag. The first
# version of this script invented one, so pass 1 produced zero files and certified nothing.
CLI=""
if   [ -x "$VENV/bin/xberg" ];     then CLI="$VENV/bin/xberg"
elif [ -x "$VENV/bin/kreuzberg" ]; then CLI="$VENV/bin/kreuzberg"; fi
say ""; ok "extraction entry point: python API${CLI:+  (CLI also present: ${CLI##*/})}"

# STUB GUARD — refuse to certify a placeholder. `pip install xberg` resolves to the 0.1.0 alias package
# (see the pin comment at the top), which imports but extracts nothing. Without this check the two passes
# would trivially agree — both producing nothing — and the script would report a clean bill of health for
# a library it never actually exercised. A verification that can pass without doing the work is worse than
# no verification, so prove an extraction entry point EXISTS before running the passes.
cat >"$VERIFY_HOME/check_api.py" <<'PYEOF'
import sys
try:
    import xberg as X
except ImportError:
    try:
        import kreuzberg as X
    except ImportError:
        sys.exit("neither xberg nor kreuzberg is importable")
if not any(callable(getattr(X, n, None)) for n in
           ("extract_file_sync", "extract_file", "extract_sync", "extract")):
    sys.exit(f"{X.__name__} imports but exposes no extract* function (placeholder package?)")
print(f"  extraction API confirmed in {X.__name__}")
PYEOF
if [ -x "$PY" ]; then
  if ! "$PY" "$VERIFY_HOME/check_api.py"; then
    err "The installed package exposes NO extraction entry point — that is the placeholder alias,"
    err "not the real library. Nothing has been certified. Re-run with an explicit version:"
    err "    XBERG_PIN='kreuzberg[tesseract]==4.10.2' bash ${0##*/} teardown --go"
    err "    XBERG_PIN='kreuzberg[tesseract]==4.10.2' bash ${0##*/} --go"
    exit 2
  fi
fi

cat >"$VERIFY_HOME/extract_all.py" <<'PYEOF'
"""extract_all.py OUTDIR DOC...  — extract each doc, write <name>.txt. Local backends only."""
import sys, pathlib
outdir = pathlib.Path(sys.argv[1]); outdir.mkdir(parents=True, exist_ok=True)
try:
    import xberg as X
except ImportError:
    import kreuzberg as X
fn = None
for name in ("extract_file_sync", "extract_file", "extract_sync", "extract"):
    fn = getattr(X, name, None)
    if fn is not None:
        break
if fn is None:
    sys.exit("no extraction entry point found in the installed package")
for src in sys.argv[2:]:
    p = pathlib.Path(src)
    try:
        res = fn(str(p))
        if hasattr(res, "__await__"):
            import asyncio
            res = asyncio.run(res)
        text = getattr(res, "content", None) or getattr(res, "text", None) or str(res)
    except Exception as e:                      # a failure must be recorded, never silently skipped
        text = f"<<EXTRACTION-ERROR {type(e).__name__}: {e}>>"
    (outdir / (p.name + ".txt")).write_text(text, encoding="utf-8", errors="replace")
PYEOF

run_extract() {  # run_extract <outdir> [wrapper...] — wrapper prefixes the command (e.g. unshare)
  local outdir="$1"; shift
  "$@" "$PY" "$VERIFY_HOME/extract_all.py" "$outdir" "$DOCS"/*
}
fingerprint() { find "$1" -type f | LC_ALL=C sort | xargs -r sha256sum 2>/dev/null | awk '{print $1}' | sha256sum | awk '{print $1}'; }
show_log() { say "  --- last 15 lines of ${1##*/} ---"; tail -15 "$1" 2>/dev/null | sed 's/^/    /'; }

# ---- pass 1: with network ----------------------------------------------------------------------
hdr "Pass 1 — extraction WITH network (models may download now)"
rm -rf "${OUT_NET:?}"/* 2>/dev/null
run_extract "$OUT_NET" >>"$LOGS/pass1.log" 2>&1 || warn "pass 1 returned non-zero"
n1="$(find "$OUT_NET" -type f 2>/dev/null | wc -l)"; fp1="$(fingerprint "$OUT_NET")"
say "  outputs: $n1   fingerprint: ${fp1:0:16}…"
# Fail FAST and loudly. A pass that extracted nothing cannot certify anything, and continuing would
# only produce a second empty result that trivially "matches" the first.
if [ "$n1" -eq 0 ]; then
  err "Pass 1 produced NO output — extraction did not run, so nothing can be certified."
  show_log "$LOGS/pass1.log"
  err "Fix the extraction call before trusting any verdict from this script."
  exit 2
fi
# Sanity: the output must actually contain extracted text, not empty files or error markers.
if grep -rq 'EXTRACTION-ERROR' "$OUT_NET" 2>/dev/null; then
  warn "some documents recorded an extraction error (kept, not hidden):"
  grep -rh 'EXTRACTION-ERROR' "$OUT_NET" | sed 's/^/    /' | head -5
fi
ok "pass 1 extracted $n1 documents"

# ---- pass 2: prove it needs no network ---------------------------------------------------------
# Layered, because Ubuntu 23.10+ restricts unprivileged user namespaces by AppArmor default, so the
# clean `unshare -rn` is simply denied on a stock 24.04 box. Strongest available method wins:
#   A  unshare -rn                    prevention, no privileges          (blocked on stock Ubuntu 24.04)
#   B  sudo unshare -n + setpriv      prevention, needs sudo             (--sudo-netns)
#   C  strace network syscall audit   observation, no privileges         (evidence, not prevention)
hdr "Pass 2 — prove extraction needs no network"
METHOD=""; fp2=""; n2=0
try_pass2() {  # try_pass2 <label> <wrapper...>
  local label="$1"; shift
  rm -rf "${OUT_OFF:?}"/* 2>/dev/null
  if run_extract "$OUT_OFF" "$@" >>"$LOGS/pass2.log" 2>&1; then
    n2="$(find "$OUT_OFF" -type f 2>/dev/null | wc -l)"
    [ "$n2" -gt 0 ] && { METHOD="$label"; fp2="$(fingerprint "$OUT_OFF")"; return 0; }
  fi
  return 1
}

if unshare -rn true 2>/dev/null && try_pass2 "network namespace (unprivileged)" unshare -rn --; then
  ok "ran with the network namespace removed — no privileges needed"
elif [ "$SUDO_NETNS" = 1 ]; then
  say "  unprivileged namespaces unavailable — using sudo to create one (you may be prompted)"
  # root makes the empty netns, then setpriv drops straight back to you, so nothing in the sandbox
  # ends up root-owned and the extractor never runs with privileges.
  if sudo -v && try_pass2 "network namespace (sudo, dropped back to $(id -un))" \
        sudo unshare -n -- setpriv --reuid "$(id -u)" --regid "$(id -g)" --clear-groups --; then
    ok "ran inside a root-created network namespace, as your own user"
  fi
fi

STRACE_RESULT=""
if [ -z "$METHOD" ] || [ "$STRACE_ALWAYS" = 1 ]; then
  if command -v strace >/dev/null 2>&1; then
    say "  running a syscall audit (observes outbound connections rather than preventing them)"
    rm -rf "${OUT_OFF:?}"/* 2>/dev/null
    strace -f -qq -e trace=network -o "$LOGS/strace.log" \
      "$PY" "$VERIFY_HOME/extract_all.py" "$OUT_OFF" "$DOCS"/* >>"$LOGS/pass2.log" 2>&1
    n2="$(find "$OUT_OFF" -type f 2>/dev/null | wc -l)"; [ "$n2" -gt 0 ] && fp2="$(fingerprint "$OUT_OFF")"
    # Only AF_INET/AF_INET6 connects leave the machine. AF_UNIX and AF_NETLINK are local IPC.
    outbound="$(grep -E 'connect\(' "$LOGS/strace.log" 2>/dev/null | grep -E 'AF_INET' | grep -v '127\.0\.0\.1\|::1' || true)"
    if [ -n "$outbound" ]; then
      STRACE_RESULT="dirty"
      err "OUTBOUND CONNECTION ATTEMPTS OBSERVED during extraction:"
      printf '%s\n' "$outbound" | sed 's/^/    /' | head -10
    else
      STRACE_RESULT="clean"
      ok "syscall audit: no outbound (AF_INET) connections during extraction"
    fi
    [ -z "$METHOD" ] && METHOD="syscall audit (strace)"
  else
    warn "strace is not installed — no fallback evidence available (sudo apt install strace)"
  fi
fi

# ---- verdict -----------------------------------------------------------------------------------
hdr "VERDICT"
rc=0
case "$METHOD" in
  "network namespace"*)
    if [ "$fp1" = "$fp2" ]; then
      ok "PROVEN: extraction is byte-identical with the network REMOVED (${METHOD})."
      ok "The extractor requires no outbound connection at runtime."
    else
      err "Outputs DIFFER between the networked and network-less passes (${METHOD})."
      err "Something behaved differently when the network was reachable. Do NOT point this at"
      err "family documents until that is understood. Compare: $OUT_NET vs $OUT_OFF"; rc=1
    fi ;;
  "syscall audit"*)
    if [ "$STRACE_RESULT" = clean ] && [ "$fp1" = "$fp2" ]; then
      ok "STRONG EVIDENCE: no outbound connections observed, and output is identical."
      say "  This observed one run rather than preventing egress outright. To get the stronger"
      say "  proof, re-run with:   bash ${0##*/} --go --sudo-netns"
    else
      err "Syscall audit did not come back clean. Treat as UNPROVEN."; rc=1
    fi ;;
  *)
    warn "Could not run any offline proof on this box."
    warn "  unprivileged namespaces are blocked (Ubuntu 23.10+ AppArmor default) and strace is absent."
    warn "VERDICT: UNPROVEN — do not point the extractor at family documents on this evidence."
    say  "  Options:   bash ${0##*/} --go --sudo-netns      (root creates the namespace, runs as you)"
    say  "             sudo apt install strace && bash ${0##*/} --go"
    rc=2 ;;
esac

if [ "$rc" = 0 ]; then
  say ""
  say "  Caveats that remain before real documents:"
  say "   - first-use model downloads (OCR weights) need network ONCE; this proves RUNTIME independence"
  say "   - this covered text/eml/csv/pdf. Exercise the OCR path with a real IMAGE before trusting it there"
  say "   - keep every *_API_KEY unset; the cloud backends are inert without one"
fi
say ""
say "Installed licence + version are reported above — that settles the MIT/Elastic-2.0 question."
say "Sandbox: $VERIFY_HOME   ·   remove it with:  bash ${0##*/} teardown --go"
exit "$rc"
