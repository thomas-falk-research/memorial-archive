#!/usr/bin/env bash
# ci/search-roundtrip.sh — prove the family can FIND the will: full-text + OCR search end to end.
#
# The acceptance test for the whole archive is "find the estate plan — including a SCANNED will — and
# every other document." This drives the ACTUAL archive-index / archive-search / archive-find commands
# (extracted from archive-search-setup.sh, the same way the shellcheck pass and the backup drills do)
# against a scratch archive seeded like the real one — copies from several labelled "devices", a mix
# of born-digital documents, and the committed SCANNED-will fixture (an image-only PDF) — and asserts:
#
#   0. preconditions with teeth: the fixture is image-only (no text layer), and neither the OCR marker
#      nor any estate-planning word appears in a FILENAME — so any hit below can ONLY come from OCR;
#   1. archive-index builds the indexes over all the devices;
#   2. archive-search finds the SCANNED will by a marker that exists only inside the image — i.e. OCR;
#   3. archive-search finds the scanned will by the family's real estate-planning queries (will,
#      testament, executor, beneficiary, estate, trust, probate, "power of attorney", ...) — all via OCR;
#   4. archive-search finds BORN-DIGITAL documents on other devices (insurance / beneficiary / 401k);
#   5. archive-find finds files by NAME (the plocate index), including across devices;
#   6. results span MULTIPLE device labels (provenance is preserved and searchable).
#
# Driving the real commands means a regression in our index/search logic (the recoll OCR config, the
# topdirs/skip list, the query formatting) fails here. It needs recoll + tesseract + poppler (the
# feature's real dependencies); it self-skips cleanly when those aren't installed. Runs as any user
# and touches only a mktemp scratch dir.
set -uo pipefail
# recoll/tesseract emit non-ASCII; keep them happy regardless of the caller's locale.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1

# Everything the index/OCR/search path needs. Missing any one means we can't prove OCR here — skip,
# don't fail (CI installs them; a lean local box may not have them).
for t in recollindex recollq plocate updatedb.plocate tesseract pdftoppm pdftotext; do
  if ! command -v "$t" >/dev/null 2>&1; then
    warn "$t not installed — skipping the search/OCR drill (CI installs recoll + tesseract + poppler)."
    exit 0
  fi
done

FIXTURE="ci/fixtures/will-scanned.pdf"
TOKEN="OCRWILLMARKER"        # embedded ONLY inside the scanned image (see ci/fixtures/make-fixtures.sh)
[[ -s "$FIXTURE" ]] || { bad "missing committed fixture $FIXTURE — regenerate it with ci/fixtures/make-fixtures.sh"; exit 1; }

# The everyday estate-planning searches the family will actually type. None of them appear in the
# scanned file's NAME, so each hit on the scan proves recoll OCR'd and indexed the image's text.
ESTATE_QUERIES=( "will" "testament" "executor" "beneficiary" "estate" "trust" "probate" '"power of attorney"' '"last will and testament"' )
# Single words from the above, for the filename-absence precondition (multi-word phrases can't be a
# single filename token anyway).
ESTATE_NAME_RE='will|testament|executor|beneficiary|estate|trust|probate|attorney'

fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the real installed-command bodies so we test our commands, not a reimplementation.
extract_embedded_commands "$WORK/cmds"
IDX="$WORK/cmds/archive-search-setup.sh__archive-index.sh"
SEARCH="$WORK/cmds/archive-search-setup.sh__archive-search.sh"
FIND="$WORK/cmds/archive-search-setup.sh__archive-find.sh"
for f in "$IDX" "$SEARCH" "$FIND"; do
  [[ -s "$f" ]] || { bad "could not extract a search command body from archive-search-setup.sh ($f)"; exit 1; }
done

# Scratch archive seeded like the real one: incoming/<device-label>/<timestamp>/data/... The scanned
# will lands on one "device" under a NEUTRAL filename (scan-2019-001.pdf — no estate words in the
# name, so finding it can only be by OCR'd content); born-digital paperwork on others; a SOURCE file
# named SHA256SUMS as a decoy.
A="$WORK/archive"
dead="$A/incoming/deadpc1-nvme/20260101-000000/data"
usb="$A/incoming/usb-blue-32g/20260102-000000/data"
live="$A/incoming/live-pc-dad-desktop/20260103-000000/data"
mkdir -p "$dead" "$usb/nested" "$live" "$WORK/xdg"

WILL="$dead/scan-2019-001.pdf"
cp "$FIXTURE" "$WILL"                                  # the SCANNED will (filename has NO estate words)
printf 'Life insurance policy no. 884213. Primary beneficiary: the estate.\n' > "$usb/insurance-policy.txt"
printf 'Warranty deed to the family home. 401k rollover statement enclosed.\n' > "$usb/home-deed.txt"
printf 'Holiday photos and recipes — nothing legal here.\n'                    > "$live/misc-notes.txt"
printf 'decoy manifest\n'                                                      > "$usb/nested/SHA256SUMS"

# Isolation: a scratch XDG config the commands read LAST, so it overrides any real /etc config for
# this run only (same trick archive-selftest uses). OCR explicitly on; index lives under the archive.
cat > "$WORK/xdg/archive-ingest.conf" <<CONF
ARCHIVE_ROOT=$A
OCR_ENABLE=true
OCR_LANG=eng
CONF
run_cmd() { XDG_CONFIG_HOME="$WORK/xdg" bash "$1" "${@:2}"; }
# Does archive-search for these terms return a path containing <needle>?
search_hits() { local needle="$1"; shift; run_cmd "$SEARCH" "$@" 2>/dev/null | grep -qF "$needle"; }

hdr "0. preconditions (so a hit can only be OCR, never a filename/text-layer shortcut)"
if [[ -z "$(pdftotext "$FIXTURE" - 2>/dev/null | tr -d '[:space:]')" ]]; then
  ok "the scanned fixture has no extractable text layer — reading it requires OCR"
else
  bad "fixture PDF has a text layer — it would not exercise OCR; regenerate it"; fails=1
fi
if find "$A" -type f | grep -qF "$TOKEN" || grep -rqF "$TOKEN" "$dead" "$usb" "$live" 2>/dev/null; then
  bad "the OCR marker leaked into a filename or a born-digital file — the OCR proof would be moot"; fails=1
else
  ok "the OCR marker appears in no filename and no born-digital file (only inside the scan)"
fi
if find "$A" -type f -printf '%f\n' | grep -qiE "$ESTATE_NAME_RE"; then
  bad "an estate-planning word appears in a FILENAME — the content-search proofs would be moot"; fails=1
else
  ok "no estate-planning word appears in any filename — finding the will proves OCR of its content"
fi

hdr "1. build the indexes (archive-index, OCR on)"
if run_cmd "$IDX" >"$WORK/index.log" 2>&1; then
  ok "archive-index built the full-text + filename indexes over all three devices"
else
  bad "archive-index failed"; sed 's/^/      /' "$WORK/index.log"; fails=1
fi

hdr "2. THE acceptance test — the SCANNED will is found by its OCR'd content"
if search_hits "scan-2019-001.pdf" "$TOKEN"; then
  ok "archive-search \"$TOKEN\" returned the scanned will — recoll OCR'd the image and indexed its text"
else
  bad "archive-search did NOT find the scanned will by its OCR-only marker — OCR is not working"
  printf '      index log tail:\n'; tail -n 15 "$WORK/index.log" | sed 's/^/      /'; fails=1
fi

hdr "3. the family's real estate-planning queries all find the scanned will (via OCR)"
miss=0
for q in "${ESTATE_QUERIES[@]}"; do
  if search_hits "scan-2019-001.pdf" "$q"; then
    ok "archive-search $q → found the will"
  else
    bad "archive-search $q → did NOT find the will"; miss=1
  fi
done
(( miss )) && fails=1

hdr "4. born-digital paperwork on other devices is found by content"
if search_hits "insurance-policy.txt" insurance beneficiary; then
  ok "archive-search insurance beneficiary → found the born-digital insurance document"
else
  bad "born-digital content search (insurance/beneficiary) failed"; fails=1
fi
if search_hits "home-deed.txt" 401k; then
  ok "archive-search 401k → found the born-digital deed/401k document"
else
  bad "born-digital content search (401k) failed"; fails=1
fi

hdr "5. archive-find locates files by NAME (the filename index)"
if run_cmd "$FIND" '*.pdf' 2>/dev/null | grep -qF "scan-2019-001.pdf"; then
  ok "archive-find '*.pdf' located the scanned will by filename"
else
  bad "archive-find '*.pdf' did not list the scanned PDF"; fails=1
fi
if run_cmd "$FIND" insurance 2>/dev/null | grep -qF "insurance-policy.txt"; then
  ok "archive-find insurance located the insurance file by name"
else
  bad "archive-find insurance did not list the insurance file"; fails=1
fi

hdr "6. results span multiple devices (provenance preserved + searchable)"
# A name search broad enough to hit every device's payload should return paths under >1 device label.
labels="$(run_cmd "$FIND" 20260 2>/dev/null | sed -nE 's#.*/incoming/([^/]+)/.*#\1#p' | sort -u)"
n_labels="$(printf '%s\n' "$labels" | grep -c .)"
if (( n_labels >= 2 )); then
  ok "found documents across $n_labels device labels: ${labels//$'\n'/ }"
else
  bad "expected matches across multiple device labels, saw: ${labels:-none}"; fails=1
fi

hdr "Summary"
if (( fails )); then bad "search/OCR drill FAILED — see above."; else ok "search/OCR drill passed (the scanned will is findable)."; fi
exit "$fails"
