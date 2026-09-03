#!/usr/bin/env bash
# ci/run.sh — run every static check the CI runs, in one go. Use it locally before you push:
#   ./ci/run.sh
# It runs the syntax gate, shellcheck (outer + embedded command bodies), and the compose validator,
# then prints a single pass/fail summary. Exits non-zero if any check failed, so CI can gate on it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --static skips the three drills that drive REAL system tools (rsync, restic, recoll) against
# scratch directories. They are safe — every one uses mktemp, overrides ARCHIVE_ROOT/BACKUP_ROOT,
# and never sudo's — but on the family's box their output reads like a live backup of the archive,
# which is alarming enough that someone reasonably stopped to ask. Use --static when you only want
# the gates that matter for a code or fixture change.
#
# CI calls this with no flags, so coverage there is unchanged. What was skipped is always printed:
# a check suite that quietly runs less than you think is worse than one that takes longer.
STATIC_ONLY=false
for a in "$@"; do
  case "$a" in
    --static) STATIC_ONLY=true ;;
    -h|--help) printf 'Usage: %s [--static]\n  --static  skip the rsync/restic/recoll drills (scratch-only, but slow and noisy)\n' "${0##*/}"; exit 0 ;;
    *) printf 'unknown option: %s (try --help)\n' "$a" >&2; exit 2 ;;
  esac
done
# shellcheck source=/dev/null
. "$here/lib.sh"

fail=0
"$here/check-syntax.sh"   || fail=1
"$here/shellcheck-all.sh" || fail=1
python3 "$here/validate-compose.py" || fail=1
# Dynamic drills — each self-skips cleanly when its tools (rsync / restic / recoll+tesseract) are
# absent, so this stays a one-command local "run everything".
"$here/paperless-upgrade-guard.sh" || fail=1
"$here/openarchiver-env-guard.sh" || fail=1
"$here/openarchiver-preflight-guard.sh" || fail=1
"$here/openarchiver-ocr-fixture-guard.sh" || fail=1
skipped=0
if [[ "$STATIC_ONLY" == true ]]; then
  skipped=3
else
  "$here/backup-roundtrip.sh" || fail=1
  "$here/restic-roundtrip.sh" || fail=1
  "$here/search-roundtrip.sh" || fail=1
fi

hdr "Summary"
if (( skipped )); then
  warn "--static: SKIPPED $skipped drill(s) — rsync backup, restic restore, search/OCR."
  warn "  Those are the end-to-end recovery proofs. Run ./ci/run.sh with no flags before a release."
fi
if (( fail )); then
  bad "Static checks FAILED — see the findings above."
else
  ok "All static checks passed."
fi
exit "$fail"
