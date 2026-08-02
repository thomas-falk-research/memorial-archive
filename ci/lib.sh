#!/usr/bin/env bash
# ci/lib.sh — shared helpers for the memorial-archive CI checks. Sourced by the other ci/*.sh;
# it only defines functions and colour variables (no side effects when sourced).

# Colour only on a TTY, so CI logs stay plain text.
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_CYN=$'\033[0;36m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
fi

hdr()  { printf '\n%s== %s%s\n' "$C_CYN" "$*" "$C_RST"; }
ok()   { printf '  %s✓%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n'  "$C_YEL" "$C_RST" "$*"; }
bad()  { printf '  %s✗%s %s\n'  "$C_RED" "$C_RST" "$*"; }

# repo_root — the directory holding the setup scripts (the parent of ci/).
repo_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

# all_shell_scripts — every shell script in the repo, one per line, from repo root.
#
# This used to be the literal glob `*.sh ci/*.sh`, which silently excluded every script in a
# subdirectory — including openarchiver/verify-openarchiver.sh and openarchiver/stage-mailbox.sh,
# the two tools that stand between a master mailbox and an app we do not fully trust. The most
# safety-critical code in the repo was the only code CI never parsed or linted. Enumerating from
# git (with a filesystem fallback for a tarball checkout) means a new subdirectory is covered the
# day it appears, rather than the day someone remembers to extend a glob.
#
# --cached --others is not a detail. Plain `git ls-files` lists only TRACKED files, so a script that
# has just been written and not yet committed is invisible to the gates — which is precisely the
# file most likely to contain a fresh mistake. That bug shipped here once: a new script passed CI
# while it was untracked and failed the moment it was committed, having never been linted at all.
# --exclude-standard keeps .gitignore honoured so build output is still skipped.
all_shell_scripts() {
  local root; root="$(repo_root)"
  ( cd "$root" || return 1
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git ls-files --cached --others --exclude-standard '*.sh'
    else
      find . -name '*.sh' -type f -not -path './.git/*' | sed 's|^\./||'
    fi | sort -u
  )
}

# extract_embedded_commands <destdir>
# Each setup script installs its commands with `sudo tee /usr/local/bin/<cmd> >/dev/null <<'SCRIPT'
# ... SCRIPT`. The outer shellcheck sees that heredoc as opaque text, so the (often large) command
# body is never linted on its own. Write every such body to <destdir>/<setup-script>__<cmd>.sh so it
# can be shellcheck'd directly. A file may hold several blocks; each lands in its own file.
extract_embedded_commands() {
  local dest="$1" root f
  root="$(repo_root)"
  mkdir -p "$dest"
  for f in "$root"/*.sh; do
    awk -v outdir="$dest" -v file="$(basename "$f")" '
      /^sudo tee \/usr\/local\/bin\/[A-Za-z0-9_-]+ >\/dev\/null <<.SCRIPT.$/ {
        cmd=$0; sub(/.*\/usr\/local\/bin\//,"",cmd); sub(/ .*/,"",cmd);
        out=outdir "/" file "__" cmd ".sh"; inblk=1; next
      }
      inblk && /^SCRIPT$/ { inblk=0; close(out); next }
      inblk { print > out }
    ' "$f"
  done
}
