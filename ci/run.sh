#!/usr/bin/env bash
# ci/run.sh — run every static check the CI runs, in one go. Use it locally before you push:
#   ./ci/run.sh
# It runs the syntax gate, shellcheck (outer + embedded command bodies), and the compose validator,
# then prints a single pass/fail summary. Exits non-zero if any check failed, so CI can gate on it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/lib.sh"

fail=0
"$here/check-syntax.sh"   || fail=1
"$here/shellcheck-all.sh" || fail=1
python3 "$here/validate-compose.py" || fail=1
# Dynamic backup/restore drills — each self-skips cleanly when its tool (rsync / restic) is absent,
# so this stays a one-command local "run everything".
"$here/backup-roundtrip.sh" || fail=1
"$here/restic-roundtrip.sh" || fail=1

hdr "Summary"
if (( fail )); then
  bad "Static checks FAILED — see the findings above."
else
  ok "All static checks passed."
fi
exit "$fail"
