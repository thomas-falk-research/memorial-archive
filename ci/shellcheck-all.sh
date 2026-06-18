#!/usr/bin/env bash
# ci/shellcheck-all.sh — shellcheck the outer setup scripts AND every command they embed.
#
# Setup scripts write their installed commands with `sudo tee /usr/local/bin/<cmd> <<'SCRIPT' ...
# SCRIPT`. The outer shellcheck treats that heredoc as opaque text, so the embedded command — often
# the bulk of the real logic — would never be linted. We extract each body and shellcheck it alone.
#
# Severity defaults to `style` (the strictest gate, matching the project's clean baseline); override
# with SHELLCHECK_SEVERITY=error|warning|info|style.
set -uo pipefail
# The ✓/·/em-dash characters in the scripts' output strings make shellcheck choke under a C locale
# ("commitBuffer: invalid character"), so force UTF-8.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1
sev="${SHELLCHECK_SEVERITY:-style}"

if ! command -v shellcheck >/dev/null 2>&1; then
  bad "shellcheck is not installed (apt-get install -y shellcheck)"; exit 2
fi
printf 'using %s\n' "$(shellcheck --version | awk '/version:/{print "shellcheck "$2}')"

rc=0
hdr "shellcheck -S $sev — outer scripts"
for f in *.sh ci/*.sh; do
  if out=$(shellcheck -S "$sev" "$f" 2>&1); then ok "$f"; else bad "$f"; printf '%s\n' "$out"; rc=1; fi
done

hdr "shellcheck -S $sev — embedded installed-command bodies"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
extract_embedded_commands "$tmp"
shopt -s nullglob
bodies=("$tmp"/*.sh)
if (( ${#bodies[@]} == 0 )); then
  bad "no embedded command bodies were extracted — the extractor is broken"; exit 1
fi
for b in "${bodies[@]}"; do
  name="$(basename "$b" .sh)"
  # -s bash: extracted bodies may lack a shebang; they are all bash.
  if out=$(shellcheck -S "$sev" -s bash "$b" 2>&1); then ok "$name"; else bad "$name"; printf '%s\n' "$out"; rc=1; fi
done
printf '%s(%d embedded command bodies checked)%s\n' "$C_CYN" "${#bodies[@]}" "$C_RST"
exit "$rc"
