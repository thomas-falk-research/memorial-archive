#!/usr/bin/env bash
#
# archive-restic-setup.sh — add ENCRYPTED, deduplicated off-site snapshots of the archive with
# restic, ALONGSIDE the plain rsync mirror (archive-backup). Two independent safety nets:
#
#   * rsync (archive-backup): a plain, browsable, tool-free copy + SHA-256 verification.
#   * restic (this):          encrypted + deduplicated history (many dated snapshots in little space),
#                             so a lost/edited/ransomwared file can be recovered from an earlier point.
#
# The restic repository lives on the SAME off-site target as rsync ($BACKUP_ROOT/restic by default).
# restic runs as YOU (the regular user) — exactly like the rsync copy — so it writes to whatever
# target rsync already uses (external drive or Tailscale share) with no privilege surprises.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-restic-setup.sh`).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

PASS_FILE="${RESTIC_PASSWORD_FILE:-/etc/archive-restic.pass}"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  Installs 'restic' and the 'archive-restic' command for encrypted, deduplicated off-site
  snapshots of the archive (alongside the rsync backup). Creates a repository passphrase once.
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: RESTIC_REPO (default \$BACKUP_ROOT/restic), RESTIC_PASSWORD_FILE (default ${PASS_FILE}).
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

[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
export DEBIAN_FRONTEND=noninteractive

ARCHIVE_ROOT="/srv/archive"; BACKUP_ROOT="/srv/backup"
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
RESTIC_REPO="${RESTIC_REPO:-$BACKUP_ROOT/restic}"

log "This will set up encrypted off-site snapshots (restic), using sudo:"
printf '    - install: restic\n'
printf '    - command: /usr/local/bin/archive-restic   (backup · snapshots · check · restore)\n'
printf '    - repository: %s   (encrypted; alongside the rsync mirror)\n' "$RESTIC_REPO"
printf '    - passphrase: %s   (root-protected; you MUST record it off the box)\n' "$PASS_FILE"
printf '    - runs as you (%s) — same as the rsync backup\n' "$(id -un)"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi
sudo -v

if ! command -v restic >/dev/null 2>&1; then
  log "Installing restic"
  sudo apt-get update -y
  sudo apt-get install -y restic || die "Could not install restic (check your network / apt)."
fi
info "restic: $(restic version 2>/dev/null | awk '{print $2}')"

# Create the repository passphrase ONCE, then reuse it forever. Rotating it would orphan the existing
# snapshots, so a re-run must never regenerate it. Owned by YOU + mode 600 so 'archive-restic' can read
# it without sudo (cron-friendly) while staying unreadable to other users.
log "Setting up the repository passphrase (${PASS_FILE})"
fresh_pass=false
if sudo test -s "$PASS_FILE"; then
  info "Re-using the existing passphrase (never rotated — that would orphan your snapshots)."
else
  pass="$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '\n')"
  [[ -n "$pass" ]] || die "Could not generate a passphrase."
  printf '%s\n' "$pass" | sudo tee "$PASS_FILE" >/dev/null
  fresh_pass=true
fi
sudo chown "$(id -un):$(id -gn)" "$PASS_FILE"
sudo chmod 600 "$PASS_FILE"

log "Installing /usr/local/bin/archive-restic"
sudo tee /usr/local/bin/archive-restic >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-restic — encrypted, deduplicated off-site snapshots of the archive (restic), alongside the
# rsync mirror. Runs as you (no sudo): reads the user-owned passphrase file and writes to the same
# off-site target rsync uses. Usage:
#   archive-restic backup            back up the archive, prune old snapshots, then verify (check)
#   archive-restic snapshots         list the dated snapshots
#   archive-restic check             verify repository integrity
#   archive-restic restore <id> --target <dir>    restore a snapshot ('latest' = newest)
#   archive-restic <any restic args>             passthrough (stats, find, ls, diff, unlock, ...)
set -uo pipefail

for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
RESTIC_REPO="${RESTIC_REPO:-$BACKUP_ROOT/restic}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/archive-restic.pass}"
REQUIRE_SEPARATE_BACKUP="${REQUIRE_SEPARATE_BACKUP:-true}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
# Retention: plenty of recent points, thinning with age. Override in /etc/archive-ingest.conf.
KEEP_LAST="${RESTIC_KEEP_LAST:-3}"
KEEP_DAILY="${RESTIC_KEEP_DAILY:-7}"
KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-5}"
KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
export RESTIC_REPOSITORY="$RESTIC_REPO" RESTIC_PASSWORD_FILE

if [[ -t 1 ]]; then r=$'\033[1;31m'; g=$'\033[1;32m'; y=$'\033[1;33m'; c=$'\033[0;36m'; z=$'\033[0m'; else r=""; g=""; y=""; c=""; z=""; fi
ok()   { printf '%s✓%s %s\n' "$g" "$z" "$*"; }
err()  { printf '%s✗ %s%s\n' "$r" "$*" "$z" >&2; }
note() { printf '%s%s%s\n' "$c" "$*" "$z"; }

need_pass() {
  [[ -r "$RESTIC_PASSWORD_FILE" ]] || { err "Passphrase file $RESTIC_PASSWORD_FILE not readable. Run archive-restic-setup.sh."; exit 1; }
  [[ -s "$RESTIC_PASSWORD_FILE" ]] || { err "Passphrase file $RESTIC_PASSWORD_FILE is empty. Run archive-restic-setup.sh."; exit 1; }
}

repo_ready() {   # initialise the repository on first use
  if restic cat config >/dev/null 2>&1; then return 0; fi
  note "Initialising the restic repository at ${RESTIC_REPO} (first run)..."
  restic init || { err "restic init failed — is the backup target mounted and writable, and the passphrase correct?"; return 1; }
}

do_backup() {
  need_pass
  [[ -d "$ARCHIVE_ROOT/incoming" ]] || { err "No archive at $ARCHIVE_ROOT/incoming (is it mounted?). Nothing to back up."; exit 1; }
  [[ -d "$BACKUP_ROOT" ]] || { err "Backup target $BACKUP_ROOT does not exist/mounted. Mount it first (archive-storage attach-backup)."; exit 1; }

  # A backup on the SAME filesystem as the archive is not a backup. findmnt -T resolves the backing FS.
  if [[ "$REQUIRE_SEPARATE_BACKUP" == "true" ]] && command -v findmnt >/dev/null 2>&1; then
    local afs bfs
    afs="$(findmnt -no SOURCE -T "$ARCHIVE_ROOT" 2>/dev/null || true)"
    bfs="$(findmnt -no SOURCE -T "$BACKUP_ROOT" 2>/dev/null || true)"
    if [[ -z "$bfs" || "$bfs" == "$afs" ]]; then
      err "Backup target $BACKUP_ROOT is on the SAME disk as the archive (or not mounted)."
      err "Mount your off-site target there first, or set REQUIRE_SEPARATE_BACKUP=false to override."
      exit 1
    fi
  fi
  # Free-space floor on the repo's volume.
  local avail floor
  avail="$(df -PB1 "$BACKUP_ROOT" | awk 'NR==2{print $4}')"; avail="${avail:-0}"
  floor=$(( MIN_FREE_GIB * 1024 * 1024 * 1024 ))
  (( avail < floor )) && { err "Backup volume has under ${MIN_FREE_GIB} GiB free. Free space and retry."; exit 1; }

  repo_ready || exit 1

  # The 'verified' marker means the LAST run backed up AND passed an integrity check. Clear it now;
  # only re-write it after 'restic check' succeeds, so an interrupted/failed run never looks good.
  local marker="$BACKUP_ROOT/.archive-restic.verified"
  rm -f "$marker" 2>/dev/null || true

  note "Backing up ${ARCHIVE_ROOT} to the encrypted repository (this can take a while)..."
  # Mirror the rsync excludes: rebuildable indexes and recovery cruft are not worth snapshotting.
  local brc
  restic backup "$ARCHIVE_ROOT" --tag archive --one-file-system=false \
    --exclude='lost+found' --exclude='.recoll' --exclude='.plocate.db' --exclude='.derived'
  brc=$?
  if   [[ $brc -eq 0 ]]; then ok "Snapshot created."
  elif [[ $brc -eq 3 ]]; then printf '%s! some files could not be read and were skipped (see above)%s\n' "$y" "$z"
  else err "restic backup failed (exit $brc) — NOT marking verified."; exit 1; fi

  note "Pruning old snapshots (keep last ${KEEP_LAST}, daily ${KEEP_DAILY}, weekly ${KEEP_WEEKLY}, monthly ${KEEP_MONTHLY})..."
  if restic forget --prune --keep-last "$KEEP_LAST" --keep-daily "$KEEP_DAILY" \
       --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"; then
    ok "Retention applied."
  else
    printf '%s! prune reported a problem (the new snapshot is still safe; see above)%s\n' "$y" "$z"
  fi

  note "Verifying repository integrity (restic check)..."
  if restic check; then
    ok "Repository verified."
    printf '%s  restic backup verified\n' "$(date -Is)" > "$marker" 2>/dev/null || true
    ok "Encrypted off-site backup complete and verified."
  else
    err "restic check FAILED — the repository may be damaged. NOT marking verified. Investigate before relying on it."
    exit 1
  fi
}

case "${1:-}" in
  ""|-h|--help|help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    if [[ -r "$RESTIC_PASSWORD_FILE" ]]; then restic snapshots --compact 2>/dev/null | tail -n 6 || true; fi
    ;;
  backup) shift; do_backup ;;
  *) need_pass; exec restic "$@" ;;   # passthrough: snapshots, check, restore, stats, find, ...
esac
SCRIPT
sudo chmod +x /usr/local/bin/archive-restic

log "Done — encrypted off-site snapshots are ready."
cat <<EOF

    First/again, run a backup (also done by 'manage.sh -> Everyday -> Run a verified backup'):
        archive-restic backup
    Then:
        archive-restic snapshots         # the dated restore points
        archive-restic check             # re-verify integrity any time
        archive-restic restore latest --target /tmp/restore-test    # try a restore

    Notes:
      - This is IN ADDITION to the rsync mirror (archive-backup); both target ${BACKUP_ROOT}.
      - It runs as you (${USER:-$(id -un)}); no sudo needed — so it also works from cron.
      - Retention/repo/passphrase are tunable in /etc/archive-ingest.conf (RESTIC_* / RESTIC_REPO).
EOF

# Printed LAST (and only when freshly generated) so this un-resettable passphrase can't get buried
# above the notes or under a later script's output. On a re-run it is reused, never reprinted.
if [[ "$fresh_pass" == true ]]; then
  printf '\n\033[1;33m================================ RECORD THIS NOW ================================\033[0m\n'
  printf '  Your restic repository passphrase (also saved, root-protected, at %s):\n\n' "$PASS_FILE"
  printf '      \033[1m%s\033[0m\n\n' "$(sudo cat "$PASS_FILE")"
  printf '  Write it down and keep a copy OFF the box (password manager / sealed envelope).\n'
  printf '  Unlike app logins, this CANNOT be reset: without it the encrypted backup is\n'
  printf '  unrecoverable. (archive-credentials will remind you where it lives, but never shows it.)\n'
  printf '\033[1;33m================================================================================\033[0m\n'
fi
