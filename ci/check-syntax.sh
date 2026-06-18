#!/usr/bin/env bash
# ci/check-syntax.sh — parse every shell script with `bash -n` (syntax only; runs nothing).
# The cheapest gate: a typo that breaks parsing should fail in milliseconds, before shellcheck.
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1

hdr "bash -n (syntax) on every shell script"
rc=0
for f in *.sh ci/*.sh; do
  if err=$(bash -n "$f" 2>&1); then
    ok "$f"
  else
    bad "$f"; printf '%s\n' "$err"; rc=1
  fi
done

hdr "py_compile (syntax) on the Python helpers"
for p in ci/*.py; do
  if err=$(python3 -m py_compile "$p" 2>&1); then
    ok "$p"
  else
    bad "$p"; printf '%s\n' "$err"; rc=1
  fi
done
exit "$rc"
