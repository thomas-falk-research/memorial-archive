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
# Pin explicitly — never float. The assessment recommends xberg 1.0.0 final once it lands; until then the
# newest release candidate. Override with XBERG_PIN. 'kreuzberg' (v4 LTS, MIT) is the conservative pin.
XBERG_PIN="${XBERG_PIN:-xberg}"

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

GO=0; ARGS=()
for a in "$@"; do if [ "$a" = "--go" ]; then GO=1; else ARGS+=("$a"); fi; done
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
  "$PIP" install "$XBERG_PIN" >>"$LOGS/install.log" 2>&1 \
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
hits="$(grep -rlniE 'telemetry|analytics|posthog|sentry|mixpanel|phone_?home' "$VENV/lib" 2>/dev/null | head -20)"
if [ -n "$hits" ]; then
  warn "files mentioning telemetry-ish names (presence != enabled — read before trusting):"
  printf '%s\n' "$hits" | sed 's/^/    /'
else
  ok "no telemetry/analytics identifiers found in the installed package"
fi
say "  env vars in this shell that could enable a REMOTE backend (should be empty):"
env | grep -iE '^(OPENAI|ANTHROPIC|GOOGLE|GEMINI|AZURE|COHERE|MISTRAL|HF|HUGGING)' | sed 's/=.*/=<set>/' | sed 's/^/    /' \
  || true

# ---- the extraction runner ---------------------------------------------------------------------
# VERIFY-AT-INSTALL: the entry point moved with the rebrand (xberg CLI, kreuzberg CLI, or the Python
# API). Try them in order and report which one answered, rather than guessing at a name.
RUNNER=""
if   [ -x "$VENV/bin/xberg" ];     then RUNNER="cli:$VENV/bin/xberg"
elif [ -x "$VENV/bin/kreuzberg" ]; then RUNNER="cli:$VENV/bin/kreuzberg"
else RUNNER="py"; fi
say ""; ok "extraction entry point: $RUNNER"

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

run_extract() {  # run_extract <outdir> [network-wrapper...]
  local outdir="$1"; shift
  case "$RUNNER" in
    cli:*) "$@" "${RUNNER#cli:}" extract --output-dir "$outdir" "$DOCS"/* ;;
    py)    "$@" "$PY" "$VERIFY_HOME/extract_all.py" "$outdir" "$DOCS"/* ;;
  esac
}
fingerprint() { find "$1" -type f | LC_ALL=C sort | xargs -r sha256sum 2>/dev/null | awk '{print $1}' | sha256sum | awk '{print $1}'; }

# ---- pass 1: with network ----------------------------------------------------------------------
hdr "Pass 1 — extraction WITH network (models may download now)"
rm -rf "${OUT_NET:?}"/* 2>/dev/null
if run_extract "$OUT_NET" >>"$LOGS/pass1.log" 2>&1; then ok "pass 1 completed"; else warn "pass 1 returned non-zero — see $LOGS/pass1.log"; fi
n1="$(find "$OUT_NET" -type f 2>/dev/null | wc -l)"; fp1="$(fingerprint "$OUT_NET")"
say "  outputs: $n1   fingerprint: ${fp1:0:16}…"

# ---- pass 2: no network at all -----------------------------------------------------------------
hdr "Pass 2 — extraction with NO NETWORK (unshare -rn)"
if ! command -v unshare >/dev/null 2>&1; then
  warn "unshare not available — CANNOT run the offline proof. Install util-linux, or run this on the box."
  warn "VERDICT: UNPROVEN. Do not point the extractor at family documents on this evidence."
  exit 2
fi
if ! unshare -rn true 2>/dev/null; then
  warn "unprivileged network namespaces are not permitted here — CANNOT run the offline proof."
  warn "VERDICT: UNPROVEN. Do not point the extractor at family documents on this evidence."
  exit 2
fi
rm -rf "${OUT_OFF:?}"/* 2>/dev/null
if run_extract "$OUT_OFF" unshare -rn -- >>"$LOGS/pass2.log" 2>&1; then ok "pass 2 completed with no network"; else warn "pass 2 returned non-zero — see $LOGS/pass2.log"; fi
n2="$(find "$OUT_OFF" -type f 2>/dev/null | wc -l)"; fp2="$(fingerprint "$OUT_OFF")"
say "  outputs: $n2   fingerprint: ${fp2:0:16}…"

# ---- verdict -----------------------------------------------------------------------------------
hdr "VERDICT"
rc=0
if [ "$n1" -eq 0 ] || [ "$n2" -eq 0 ]; then
  err "one of the passes produced NO output — the test did not actually exercise extraction."
  err "Inconclusive. Read $LOGS/pass1.log and $LOGS/pass2.log before going further."; rc=2
elif [ "$fp1" = "$fp2" ]; then
  ok "Extraction is byte-identical WITH and WITHOUT network access."
  ok "The extractor requires NO outbound connection at runtime on these formats."
  say "  Remaining caveats before real documents:"
  say "   - first-use model downloads (OCR weights) still need network ONCE; re-run after they are cached"
  say "   - this covered text/eml/csv/pdf. Re-run with an IMAGE to exercise the OCR path before trusting it there."
  say "   - keep every *_API_KEY unset; cloud backends are inert without one."
else
  err "Outputs DIFFER between the networked and offline passes."
  err "Something behaved differently when the network was available. Do NOT point this at family"
  err "documents until that difference is understood. Compare: $OUT_NET vs $OUT_OFF"; rc=1
fi
say ""
say "Sandbox: $VERIFY_HOME   ·   remove it with:  bash ${0##*/} teardown --go"
exit "$rc"
