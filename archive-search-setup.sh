#!/usr/bin/env bash
#
# archive-search-setup.sh — Phase 2 of the digital-archive server: make everything searchable.
#
# Installs a local, GUI-free equivalent of Windows "Everything" plus full-text search:
#   * recoll   — full-text content index (PDF, Office, RTF, text, email, archives, ...).
#   * plocate  — instant filename index ("search by what it's called").
#   * readpst  — convert Outlook PST/OST mailboxes so their messages become searchable.
#   * format helpers (poppler-utils, antiword, catdoc, unrtf, p7zip) for recoll's filters.
#
# and three commands:
#   archive-index    (re)build both indexes over the archive; extracts PST/OST first. Re-run
#                    after each ingest. Index data lives ON the archive volume, not the OS disk.
#   archive-search   full-text search of file CONTENTS, with snippets.
#   archive-find     instant filename search (substring or glob).
#
# Reads ARCHIVE_ROOT from /etc/archive-ingest.conf (written by archive-ingest-setup.sh).
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-search-setup.sh`).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Packages --------------------------------------------------------------------------------
# recollcmd = recoll's CLI indexer/query without the Qt GUI (right choice for a server).
CORE_PKGS=( recollcmd plocate pst-utils poppler-utils antiword catdoc unrtf p7zip-full )
BEST_EFFORT_PKGS=( djvulibre-bin )   # DjVu text extraction; skipped if unavailable
SKIPPED=()

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt (for unattended runs)
  --help, -h  show this help and exit
Installs recoll + plocate + readpst (+ filter helpers) and the archive-index /
archive-search / archive-find commands. ARCHIVE_ROOT is read from /etc/archive-ingest.conf.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null || true
[[ "${ID:-}" == "ubuntu" ]] || warn "Targeting Ubuntu; detected ID='${ID:-unknown}'."
export DEBIAN_FRONTEND=noninteractive

# Discover ARCHIVE_ROOT so the summary is accurate (default matches the ingest installer).
ARCHIVE_ROOT="/srv/archive"
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
if [[ ! -d "$ARCHIVE_ROOT" ]]; then
  warn "Archive root '$ARCHIVE_ROOT' does not exist yet."
  warn "Run archive-ingest-setup.sh first (and ingest something) — then run 'archive-index'."
fi

log "This will install (using sudo):"
printf '    - apt packages: %s\n' "${CORE_PKGS[*]}"
printf '    - best-effort:  %s\n' "${BEST_EFFORT_PKGS[*]}"
printf '    - commands to /usr/local/bin: archive-index, archive-search, archive-find\n'
printf '    - search index stored under: %s/.recoll and %s/.plocate.db (on the archive volume)\n' "$ARCHIVE_ROOT" "$ARCHIVE_ROOT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

sudo -v

log "Installing core packages"
sudo apt-get update -y
sudo apt-get install -y "${CORE_PKGS[@]}"

log "Installing best-effort extras (skipped individually if missing)"
for pkg in "${BEST_EFFORT_PKGS[@]}"; do
  if sudo apt-get install -y "$pkg" >/dev/null 2>&1; then info "installed: $pkg"
  else warn "unavailable on this release: $pkg (skipped)"; SKIPPED+=("$pkg"); fi
done

log "Installing commands to /usr/local/bin"

info "writing archive-index"
sudo tee /usr/local/bin/archive-index >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-index — (re)build the searchable indexes over the archive: full-text content
# (recoll) and filenames (plocate). Outlook PST/OST mailboxes are extracted first so their
# messages become searchable. Incremental and safe to re-run after every ingest.
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"
PLOCATE_DB="${PLOCATE_DB:-${ARCHIVE_ROOT}/.plocate.db}"
# Use a UTF-8 locale so non-ASCII names/keywords work even from a misconfigured shell.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) : ;; *) export LC_ALL=C.UTF-8 ;; esac

c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_red=$'\033[1;31m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

command -v recollindex >/dev/null 2>&1 || { err "recollindex not found — run archive-search-setup.sh first."; exit 1; }
[[ -d "$ARCHIVE_ROOT" ]] || { err "Archive root not found: $ARCHIVE_ROOT"; exit 1; }

# 1) Extract Outlook PST/OST mailboxes into a sidecar dir so their messages get indexed.
if command -v readpst >/dev/null 2>&1; then
  note "Scanning for Outlook PST/OST mailboxes to extract..."
  while IFS= read -r -d '' pst; do
    out="${pst}.extracted"
    [[ -d "$out" && "$out" -nt "$pst" ]] && continue   # already extracted and up to date
    mkdir -p "$out"
    if readpst -r -o "$out" "$pst" >/dev/null 2>&1; then note "  extracted: $pst"
    else warn "  could not extract (skipped): $pst"; fi
  done < <(find "$ARCHIVE_ROOT/incoming" -type f \( -iname '*.pst' -o -iname '*.ost' \) -print0 2>/dev/null)
fi

# 2) Full-text index (recoll). Config + index live on the archive volume, not the OS disk.
mkdir -p "$RECOLL_CONFDIR"
if [[ ! -f "$RECOLL_CONFDIR/recoll.conf" ]]; then
  cat > "$RECOLL_CONFDIR/recoll.conf" <<EOF
# Generated by archive-index. Indexes the archive; the index itself lives here (on the
# archive volume) so it never fills the OS disk.
topdirs = ${ARCHIVE_ROOT}
skippedPaths = ${RECOLL_CONFDIR} ${PLOCATE_DB} ${ARCHIVE_ROOT}/images
followLinks = 0
EOF
fi
note "Building/updating the full-text index (incremental; can take a while on first run)..."
recollindex -c "$RECOLL_CONFDIR" >/dev/null 2>&1 || { err "recollindex failed."; exit 1; }

# 3) Filename index (plocate), scoped to the archive.
note "Building/updating the filename index..."
updatedb.plocate --database-root "$ARCHIVE_ROOT" --output "$PLOCATE_DB" --require-visibility 0 2>/dev/null \
  || warn "plocate index update failed (filename search may be stale)."

ok "Indexes updated."
printf '    full-text index : %s  (%s)\n' "$RECOLL_CONFDIR" "$(du -sh "$RECOLL_CONFDIR" 2>/dev/null | cut -f1)"
printf '    filename index  : %s\n' "$PLOCATE_DB"
printf '    search contents : archive-search "keywords"\n'
printf '    search names    : archive-find "name"\n'
SCRIPT
sudo chmod +x /usr/local/bin/archive-index

info "writing archive-search"
sudo tee /usr/local/bin/archive-search >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-search "keywords" — full-text search across the archive's CONTENTS (text, PDF, Office,
# RTF, extracted email, etc.). Prints each matching file path with a short snippet.
# Examples:  archive-search insurance policy        (files containing BOTH words)
#            archive-search '"life insurance"'       (the exact phrase)
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) : ;; *) export LC_ALL=C.UTF-8 ;; esac

c_red=$'\033[1;31m'; c_rst=$'\033[0m'
err() { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
command -v recollq >/dev/null 2>&1 || { err "recollq not found — run archive-search-setup.sh first."; exit 1; }
[[ $# -ge 1 ]] || { echo 'usage: archive-search "keywords"   (e.g. archive-search insurance policy)'; exit 2; }
[[ -d "$RECOLL_CONFDIR" ]] || { err "No search index yet. Build it first:  archive-index"; exit 1; }

# -A prints an abstract (snippet). recollq logs go to stderr; drop them. Reformat into a clean
# "path then indented snippet" listing with file:// stripped to a plain path.
recollq -c "$RECOLL_CONFDIR" -A "$@" 2>/dev/null | awk '
  /^Recoll query:/ { next }
  /^[0-9]+ results?/ { print "(" $0 ")"; print ""; next }
  /\[file:\/\// { p=$0; sub(/.*\[file:\/\//,"",p); sub(/\].*/,"",p); print p; next }
  /^ABSTRACT$/   { next }
  /^\/ABSTRACT$/ { print ""; next }
  { print "    " $0 }
'
SCRIPT
sudo chmod +x /usr/local/bin/archive-search

info "writing archive-find"
sudo tee /usr/local/bin/archive-find >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-find "name" — instant filename search across the archive (case-insensitive substring;
# glob patterns like '*.pst' also work). This is the "search by what it's called" companion to
# archive-search (which searches inside files).
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
PLOCATE_DB="${PLOCATE_DB:-${ARCHIVE_ROOT}/.plocate.db}"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) : ;; *) export LC_ALL=C.UTF-8 ;; esac

c_red=$'\033[1;31m'; c_rst=$'\033[0m'
err() { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
command -v plocate >/dev/null 2>&1 || { err "plocate not found — run archive-search-setup.sh first."; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: archive-find \"name\"   (e.g. archive-find vacation,  archive-find '*.pst')"; exit 2; }
[[ -f "$PLOCATE_DB" ]] || { err "No filename index yet. Build it first:  archive-index"; exit 1; }
exec plocate --database "$PLOCATE_DB" --ignore-case "$@"
SCRIPT
sudo chmod +x /usr/local/bin/archive-find

# ---- Summary ---------------------------------------------------------------------------------
log "Search tools installed."
cat <<EOF
    After each ingest, refresh the indexes:
      archive-index

    Then search:
      archive-search "keywords"     # inside files (content) — e.g. archive-search will testament
      archive-find  "name"          # by filename — e.g. archive-find '*.pst'

    The indexes live on the archive volume (${ARCHIVE_ROOT}/.recoll, ${ARCHIVE_ROOT}/.plocate.db),
    so they grow with the archive — not the OS disk.

    Optional: to let the family search from a browser on their iPhone/iPad, install the
    recoll web UI (not packaged) and bind it to the tailnet. See README.md ("Search from a phone").
EOF
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  warn "Optional components skipped (not fatal): ${SKIPPED[*]}"
fi
