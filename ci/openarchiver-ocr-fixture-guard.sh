#!/usr/bin/env bash
#
# ci/openarchiver-ocr-fixture-guard.sh — drill the mailbox that GATE 2 is built on.
#
# Gate 2 decides whether we can find a faxed will at all. Its evidence is a synthetic mailbox, so
# the mailbox itself has to be beyond doubt in three specific ways:
#
#   1. a token must NOT appear in the mailbox as plaintext — otherwise a search hit proves indexing,
#      not OCR, and the whole gate becomes decorative;
#   2. each attachment must arrive byte-identical to its fixture — a mangled attachment that fails
#      to OCR would read as "OCR is blind to TIFF" when the real fault was ours;
#   3. a missing fixture must be announced, never silently skipped — a gate that quietly tests one
#      format while claiming five is the exact failure this project keeps finding in itself.
#
# Runs against scratch directories with a stub `sudo`. No Docker, no install, no network.
#
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(repo_root)"
TOOL="$ROOT/openarchiver/verify-openarchiver.sh"
[ -f "$TOOL" ] || { bad "missing $TOOL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { warn "python3 absent — skipping the mbox parse drill"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; APP="$WORK/app"; FIX="$WORK/fixtures"
mkdir -p "$BIN" "$APP/import" "$FIX"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$BIN/sudo"; chmod +x "$BIN/sudo"

rc=0; cases=0
MBOX="$APP/import/ZZ-SYNTHETIC-VERIFY.mbox"

# The gate looks for fixtures next to itself; give it a scratch fixture dir it will find first.
mkdir -p "$WORK/oa"
cp "$TOOL" "$WORK/oa/verify-openarchiver.sh"
mkdir -p "$WORK/ci"; ln -s "$FIX" "$WORK/ci/fixtures"

# Resolved once, outside the call: assigning WORK from $WORK in the command prefix expands the
# OUTER value, which is right but unreadable — and shellcheck cannot tell the two apart.
GATE_SCRATCH="$WORK/scratch"
GATE_SCRIPT="$WORK/oa/verify-openarchiver.sh"

run_gate(){
  rm -f "$MBOX"
  PATH="$BIN:$PATH" OPENARCHIVER_DIR="$APP" WORK="$GATE_SCRATCH" \
    bash "$GATE_SCRIPT" ocr 2>&1
}

# ------------------------------------------------------------------------------------------------
hdr "With no fixtures at all it must refuse, not build an empty gate"
cases=$((cases+1))
out="$(run_gate)"
if printf '%s' "$out" | grep -qF "no OCR fixtures found"; then
  ok "no fixtures -> refuses and says so"
else
  bad "with zero fixtures the gate did not refuse"; printf '%s\n' "$out" | head -8 | sed 's/^/      /'; rc=1
fi

# ------------------------------------------------------------------------------------------------
hdr "With one fixture it tests one format — and says which it is NOT testing"
cp "$ROOT/ci/fixtures/will-scanned.pdf" "$FIX/will-scanned.pdf"
cases=$((cases+1))
out="$(run_gate)"
missing_named=1
for f in will-scanned.tif will-scanned-fax.tif will-scanned.gif will-scanned-long.pdf; do
  printf '%s' "$out" | grep -qF "$f" || missing_named=0
done
if [ "$missing_named" -eq 1 ] && printf '%s' "$out" | grep -qF "are NOT being tested"; then
  ok "absent formats are named, not silently skipped"
else
  bad "the gate did not name the formats it is failing to test"; rc=1
fi

# It must not offer guidance for a token it never attached.
#
# The listing is column-padded, so these assertions match the token and the filename on one line with
# flexible whitespace. A literal "TOKEN in NAME" grep could never match the padded output — it would
# have made this case pass without testing anything, which is how the first version of it behaved.
cases=$((cases+1))
if printf '%s' "$out" | grep -qE 'OCRTIFFMARKER +in +'; then
  bad "the gate listed a token it never attached — that invites a false blocker"; rc=1
else
  ok "only attached tokens are listed for searching"
fi

# Prove that assertion can fail: the PDF token IS attached, so it must appear in that same shape.
cases=$((cases+1))
if printf '%s' "$out" | grep -qE 'OCRWILLMARKER +in +scanned\.pdf'; then
  ok "the listing assertion is live (the attached PDF token does appear in that shape)"
else
  bad "the attached PDF token was not listed — the previous assertion cannot be trusted"; rc=1
fi

# ------------------------------------------------------------------------------------------------
hdr "The mailbox itself holds up"
cases=$((cases+1))
if [ ! -s "$MBOX" ]; then
  bad "no mailbox was written"; rc=1
else
  if python3 - "$MBOX" "$FIX/will-scanned.pdf" <<'PY'
import mailbox, sys, hashlib
mb = mailbox.mbox(sys.argv[1])
fixture = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
found = False
for m in mb:
    for part in m.walk():
        if part.get_filename() == "scanned.pdf":
            got = hashlib.sha256(part.get_payload(decode=True)).hexdigest()
            if got != fixture:
                print("attachment does NOT match the fixture"); sys.exit(1)
            found = True
if not found:
    print("no scanned.pdf attachment found"); sys.exit(1)
if len(mb) < 2:
    print(f"expected at least 2 messages, got {len(mb)}"); sys.exit(1)
sys.exit(0)
PY
  then ok "parses as an mbox; the attachment is byte-identical to its fixture"
  else bad "the synthetic mailbox is malformed or the attachment was corrupted"; rc=1; fi
fi

# The property the entire gate rests on.
cases=$((cases+1))
if grep -qF "OCRWILLMARKER" "$MBOX" 2>/dev/null; then
  bad "the token appears as PLAINTEXT in the mailbox — a search hit would not prove OCR"; rc=1
else
  ok "the token is nowhere in the mailbox as plaintext — only OCR can surface it"
fi

# A second format appears the moment its fixture does. The bytes are what matter here, not the
# extension, so the PDF fixture standing in as .tif exercises the discovery and MIME wiring.
cp "$ROOT/ci/fixtures/will-scanned.pdf" "$FIX/will-scanned.tif"
out="$(run_gate)"
cases=$((cases+1))
if printf '%s' "$out" | grep -qF "no token appears in the mailbox as plaintext"; then
  ok "a second format is picked up and still passes the plaintext assertion"
else
  bad "adding a second fixture broke the mailbox build"; printf '%s\n' "$out" | head -10 | sed 's/^/      /'; rc=1
fi
cases=$((cases+1))
if printf '%s' "$out" | grep -qE 'OCRTIFFMARKER +in +FaxImage\.tif'; then
  ok "the newly present format is now listed for searching"
else
  bad "a present fixture was not listed"; rc=1
fi
cases=$((cases+1))
if python3 - "$MBOX" <<'PY'
import mailbox, sys
mb = mailbox.mbox(sys.argv[1])
names = {p.get_filename() for m in mb for p in m.walk() if p.get_filename()}
sys.exit(0 if {"scanned.pdf", "FaxImage.tif"} <= names else 1)
PY
then ok "both attachments are present as separate messages"
else bad "the two formats did not both land as attachments"; rc=1; fi

# ------------------------------------------------------------------------------------------------
hdr "Summary"
if (( rc )); then bad "OCR fixture drill FAILED ($cases cases run)"
else ok "OCR fixture drill passed — $cases cases"; fi
exit "$rc"
