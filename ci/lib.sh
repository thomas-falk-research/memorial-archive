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
