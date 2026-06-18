#!/usr/bin/env bash
#
# archive-storage-setup.sh — Phase 4: storage layout + verified backups for the archive server.
#
# Installs two commands (and the packages needed to mount network backup targets):
#   archive-storage  show the storage layout/health; safely attach the archive and backup volumes
#                    via /etc/fstab (always 'nofail'; backs up + validates + rolls back; never formats).
#   archive-backup   verified, additive one-way backup of the archive to BACKUP_ROOT (e.g. a
#                    Tailscale-mounted ZFS share), re-checking every SHA256SUMS manifest afterward.
#
# Reads ARCHIVE_ROOT/BACKUP_ROOT from /etc/archive-ingest.conf (defaults: /srv/archive, /srv/backup).
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-storage-setup.sh`).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
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

ARCHIVE_ROOT="/srv/archive"; BACKUP_ROOT="/srv/backup"
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"

log "This will install (using sudo):"
printf '    - apt packages: nfs-common cifs-utils rsync (mount tailnet shares + run backups)\n'
printf '    - commands to /usr/local/bin: archive-storage, archive-backup\n'
printf '    - create the backup mountpoint: %s\n' "$BACKUP_ROOT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi
sudo -v

log "Installing packages for network shares and backups"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common cifs-utils rsync

log "Installing commands to /usr/local/bin"

info "writing archive-backup"
sudo tee /usr/local/bin/archive-backup >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-backup — verified one-way backup of the archive to BACKUP_ROOT (e.g. a Tailscale-mounted
# ZFS share). Additive by default: it copies new/changed data and NEVER deletes from the backup,
# so the backup can only ever gain data. After copying, it re-checks every SHA256SUMS manifest at
# the destination, so a backup is only declared good once it is byte-for-byte verified.
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
REQUIRE_SEPARATE_BACKUP="${REQUIRE_SEPARATE_BACKUP:-true}"
# Family apps keep their OWN data outside the archive (Paperless documents/tags, Immich DB +
# any uploaded originals). archive-backup also dumps these, best-effort, under $BACKUP_ROOT/apps.
APPS_ROOT="${APPS_ROOT:-/srv/apps}"
IMMICH_DIR="${IMMICH_DIR:-$APPS_ROOT/immich}"
PAPERLESS_DIR="${PAPERLESS_DIR:-$APPS_ROOT/paperless}"
DOCMOST_DIR="${DOCMOST_DIR:-$APPS_ROOT/docmost}"
BACKUP_APPS="${BACKUP_APPS:-true}"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
h() { numfmt --to=iec "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

# ---- restore instructions written beside each dump (a backup you can't restore is worthless) --
write_restore_paperless() {
  mkdir -p "$1"
  cat > "$1/RESTORE.txt" <<'TXT'
Restoring Paperless documents, tags and metadata
=================================================
This 'export/' folder was produced by Paperless-ngx's own document_exporter; it contains your
original documents, their OCR text, tags and metadata (manifest.json). To restore into a fresh
Paperless install on the box:

  1. Set Paperless up again:   ./manage.sh  ->  Install  ->  Documents (Paperless)
  2. Copy this 'export/' folder back to  /srv/apps/paperless/export  on the box.
  3. Import it:
       cd /srv/apps/paperless
       sudo docker compose exec -T webserver document_importer ../export </dev/null

(Adjust the path if you changed APPS_ROOT.)  Docs: https://docs.paperless-ngx.com/administration/
TXT
}
write_restore_immich() {
  mkdir -p "$1"
  cat > "$1/RESTORE.txt" <<'TXT'
Restoring Immich (albums, people/faces, tags + any uploaded originals)
======================================================================
'immich-database.sql.gz' is a full PostgreSQL dump (your albums, people, tags). 'files/' holds any
user-uploaded originals and profile images (thumbnails/transcodes were NOT backed up — Immich
regenerates them). The deceased's photos themselves live in the read-only archive, not here.

  *** Versions matter — check Immich's current restore guide first: ***
      https://immich.app/docs/administration/backup-and-restore

  1. Set Immich up again:   ./manage.sh  ->  Install  ->  Photos (Immich)
  2. Restore uploaded originals: copy this 'files/' back into Immich's UPLOAD_LOCATION
     (default /srv/apps/immich/library), keeping its subfolders (library/, upload/, profile/).
  3. Restore the database (the DB here is a bind-mount, not a named volume):
       cd /srv/apps/immich
       sudo docker compose down
       sudo rm -rf /srv/apps/immich/postgres/*
       sudo docker compose up -d database
       sleep 10
       gunzip < immich-database.sql.gz | sudo docker compose exec -T database psql --username=postgres
       sudo docker compose up -d

(Adjust the paths if you changed APPS_ROOT.)
TXT
}
write_restore_docmost() {
  mkdir -p "$1"
  cat > "$1/RESTORE.txt" <<'TXT'
Restoring Docmost (the family's notes / wiki — your own writing)
================================================================
This is the one app the family WRITES in, so this is real, irreplaceable data. Two files:
  - 'docmost-database.sql.gz' — a PostgreSQL dump of every page, space, comment and account.
  - 'docmost-storage.tar'     — the uploaded attachments and images.

You do NOT need the old secrets to restore: a fresh install creates a new database user from its
own .env, and this dump only carries your content. (A new APP_SECRET just means everyone signs in
again — the pages themselves are safe.)

  *** Versions matter — skim Docmost's current docs first: https://docmost.com/docs ***

  1. Set Docmost up again:   ./manage.sh  ->  Install  ->  Notes (Docmost)
  2. Restore the database (load it with the app stopped so nothing writes while it imports):
       cd /srv/apps/docmost
       sudo docker compose stop docmost
       gunzip < docmost-database.sql.gz | sudo docker compose exec -T db psql --username=docmost --dbname=docmost
  3. Restore the uploaded attachments/images:
       sudo docker compose start docmost
       sudo docker compose exec -T docmost tar -C /app/data/storage -xf - < docmost-storage.tar
  4. Restart so the app picks up the restored data:
       sudo docker compose restart docmost

(Adjust the paths if you changed APPS_ROOT.)
TXT
}

# ---- app data backup (best-effort; never fails or un-verifies the archive backup above) -------
# Immich and Paperless keep state OUTSIDE the archive, so backing up /srv/archive alone cannot
# rebuild them. This dumps each INSTALLED app's own data under $BACKUP_ROOT/apps/. Any problem here
# is a loud WARNING only: the archive backup stays the primary signal and remains verified.
backup_apps() {
  [[ "$BACKUP_APPS" == "true" ]] || { note "App-data backup is disabled (BACKUP_APPS=false)."; return 0; }
  command -v docker >/dev/null 2>&1 || return 0   # no docker -> no family apps to back up

  local appdst="$BACKUP_ROOT/apps" any=false rc_any=0

  # The per-app tools below send their output to the log, not the screen, so without a heads-up the
  # run looks frozen. Announce it, and prime sudo up front (visibly) so a later sudo can't block.
  if [[ -f "$PAPERLESS_DIR/docker-compose.yml" || -f "$IMMICH_DIR/docker-compose.yml" || -f "$DOCMOST_DIR/docker-compose.yml" ]]; then
    note "Backing up the family apps' own data — this can take a minute; details go to ${logf}"
    sudo -v || warn "Couldn't pre-authorize sudo; the app-data steps may prompt or be skipped."
  fi

  # --- Paperless: its own exporter preserves documents + OCR text + tags + manifest.json --------
  if [[ -f "$PAPERLESS_DIR/docker-compose.yml" ]]; then
    any=true
    note "Backing up Paperless (document_exporter)..."
    if ( cd "$PAPERLESS_DIR" && sudo docker compose exec -T webserver document_exporter ../export ) </dev/null >>"$logf" 2>&1; then
      mkdir -p "$appdst/paperless"
      local prc
      rsync -rlt --modify-window=2 "$PAPERLESS_DIR/export/" "$appdst/paperless/export/" >>"$logf" 2>&1
      prc=$?
      if [[ $prc -eq 0 || $prc -eq 23 || $prc -eq 24 ]] && [[ -s "$appdst/paperless/export/manifest.json" ]]; then
        ok "  Paperless: documents + tags exported and copied (manifest verified)."
        write_restore_paperless "$appdst/paperless"
      else
        err "  Paperless: export backup failed (rsync rc=$prc, or manifest.json missing)."; rc_any=1
      fi
    else
      err "  Paperless: could not run document_exporter (is the 'webserver' container up?)."; rc_any=1
    fi
  fi

  # --- Immich: database dump (albums/people/tags) + uploaded originals (minus regenerables) -----
  if [[ -f "$IMMICH_DIR/docker-compose.yml" ]]; then
    any=true
    note "Backing up Immich (database dump + uploaded originals)..."
    if ! command -v gzip >/dev/null 2>&1; then
      err "  Immich: gzip not found — cannot compress the DB dump."; rc_any=1
    else
      local dbuser tmp dumpf sz
      dbuser="$(sudo sed -n 's/^DB_USERNAME=//p' "$IMMICH_DIR/.env" 2>/dev/null | head -1)"; dbuser="${dbuser:-postgres}"
      tmp="$(mktemp -d)"; dumpf="$tmp/immich-database.sql.gz"
      if ( cd "$IMMICH_DIR" && sudo docker compose exec -T database pg_dumpall --clean --if-exists --username="$dbuser" ) </dev/null 2>>"$logf" | gzip > "$dumpf"; then
        sz="$(stat -c%s "$dumpf" 2>/dev/null || echo 0)"
        if gzip -t "$dumpf" 2>/dev/null && (( sz > 1024 )); then
          mkdir -p "$appdst/immich"
          local drc
          rsync -rlt --modify-window=2 "$dumpf" "$appdst/immich/" >>"$logf" 2>&1; drc=$?
          if [[ $drc -eq 0 || $drc -eq 23 || $drc -eq 24 ]]; then   # tolerate CIFS rc 23/24 like the others
            ok "  Immich: database dumped, verified ($(h "$sz")) and copied."
          else
            err "  Immich: copying the DB dump to the backup failed (rsync rc=$drc)."; rc_any=1
          fi
        else
          err "  Immich: the DB dump failed its integrity test or was empty — not trusting it."; rc_any=1
        fi
      else
        err "  Immich: could not dump the database (is the 'database' container up?)."; rc_any=1
      fi
      rm -rf "$tmp"
    fi

    # Uploaded originals + profile images. Immich writes these as root, so read them with sudo;
    # thumbs/ and encoded-video/ are skipped because Immich regenerates them on demand.
    local upl irc
    upl="$(sudo sed -n 's/^UPLOAD_LOCATION=//p' "$IMMICH_DIR/.env" 2>/dev/null | head -1)"; upl="${upl:-$IMMICH_DIR/library}"
    if sudo test -d "$upl"; then
      mkdir -p "$appdst/immich/files"
      { sudo rsync -rlt --modify-window=2 --exclude='thumbs/' --exclude='encoded-video/' "$upl/" "$appdst/immich/files/"; } >>"$logf" 2>&1
      irc=$?
      if [[ $irc -eq 0 || $irc -eq 23 || $irc -eq 24 ]]; then
        ok "  Immich: uploaded originals copied (thumbnails/transcodes skipped — regenerable)."
      else
        err "  Immich: backing up uploaded originals failed (rsync rc=$irc)."; rc_any=1
      fi
    fi
    write_restore_immich "$appdst/immich"
  fi

  # --- Docmost: the family's OWN writing (notes/wiki) — the one read-WRITE app, so irreplaceable --
  # pg_dump of the single 'docmost' database (data only) is enough: a fresh install recreates the
  # role from its .env, so we needn't back up secrets — only content. Uploads live in a named volume,
  # streamed out as a tar from inside the container (no need to know the project-prefixed name).
  if [[ -f "$DOCMOST_DIR/docker-compose.yml" ]]; then
    any=true
    note "Backing up Docmost (database dump + uploaded attachments)..."
    if ! command -v gzip >/dev/null 2>&1; then
      err "  Docmost: gzip not found — cannot compress the DB dump."; rc_any=1
    else
      local dtmp ddumpf dsz
      dtmp="$(mktemp -d)"; ddumpf="$dtmp/docmost-database.sql.gz"
      if ( cd "$DOCMOST_DIR" && sudo docker compose exec -T db pg_dump --clean --if-exists --username=docmost docmost ) </dev/null 2>>"$logf" | gzip > "$ddumpf"; then
        dsz="$(stat -c%s "$ddumpf" 2>/dev/null || echo 0)"
        if gzip -t "$ddumpf" 2>/dev/null && (( dsz > 1024 )); then
          mkdir -p "$appdst/docmost"
          local ddrc
          rsync -rlt --modify-window=2 "$ddumpf" "$appdst/docmost/" >>"$logf" 2>&1; ddrc=$?
          if [[ $ddrc -eq 0 || $ddrc -eq 23 || $ddrc -eq 24 ]]; then   # tolerate CIFS rc 23/24 like the others
            ok "  Docmost: database dumped, verified ($(h "$dsz")) and copied."
          else
            err "  Docmost: copying the DB dump to the backup failed (rsync rc=$ddrc)."; rc_any=1
          fi
        else
          err "  Docmost: the DB dump failed its integrity test or was empty — not trusting it."; rc_any=1
        fi
      else
        err "  Docmost: could not dump the database (is the 'db' container up?)."; rc_any=1
      fi
      rm -rf "$dtmp"
    fi

    # Uploaded attachments/images (the 'docmost_storage' named volume), streamed out as a tar and
    # verified by listing it. An empty store still makes a valid (tiny) tar — that's fine.
    local utmp utar usz urc
    utmp="$(mktemp -d)"; utar="$utmp/docmost-storage.tar"
    if ( cd "$DOCMOST_DIR" && sudo docker compose exec -T docmost tar -C /app/data/storage -cf - . ) </dev/null >"$utar" 2>>"$logf"; then
      usz="$(stat -c%s "$utar" 2>/dev/null || echo 0)"
      if tar -tf "$utar" >/dev/null 2>&1 && (( usz > 0 )); then
        mkdir -p "$appdst/docmost"
        rsync -rlt --modify-window=2 "$utar" "$appdst/docmost/" >>"$logf" 2>&1; urc=$?
        if [[ $urc -eq 0 || $urc -eq 23 || $urc -eq 24 ]]; then
          ok "  Docmost: uploaded attachments archived ($(h "$usz")) and copied."
        else
          err "  Docmost: copying the uploads archive to the backup failed (rsync rc=$urc)."; rc_any=1
        fi
      else
        err "  Docmost: the uploads archive was empty or unreadable — not trusting it."; rc_any=1
      fi
    else
      err "  Docmost: could not archive uploaded attachments (is the 'docmost' container up?)."; rc_any=1
    fi
    rm -rf "$utmp"
    write_restore_docmost "$appdst/docmost"
  fi

  if [[ "$any" != true ]]; then
    note "No family apps (Immich/Paperless/Docmost) installed — nothing extra to back up."
    return 0
  fi
  mkdir -p "$appdst"
  if [[ $rc_any -eq 0 ]]; then
    ok "App data backup complete and verified."
    printf '%s  apps backed up + verified\n' "$(date -Is)" > "$appdst/.apps-backup.verified" 2>/dev/null || true
  else
    rm -f "$appdst/.apps-backup.verified" 2>/dev/null || true
    warn "App data backup had problems (see above / $logf). Your ARCHIVE backup is unaffected and still verified."
  fi
  return 0
}

for _t in rsync sha256sum numfmt df du findmnt; do
  command -v "$_t" >/dev/null 2>&1 || { err "Required tool not found: $_t."; exit 1; }
done

[[ -d "$ARCHIVE_ROOT/incoming" ]] || { err "No archive found at $ARCHIVE_ROOT/incoming. Nothing to back up."; exit 1; }
[[ -d "$BACKUP_ROOT" ]] || { err "Backup root $BACKUP_ROOT does not exist. Create/mount it first (archive-storage)."; exit 1; }

# Guardrail: the backup must be a different filesystem from the archive (otherwise it is not a
# backup — a single disk failure loses both copies). findmnt -T resolves the backing filesystem.
arc_fs="$(findmnt -no SOURCE -T "$ARCHIVE_ROOT" 2>/dev/null || true)"
bak_fs="$(findmnt -no SOURCE -T "$BACKUP_ROOT" 2>/dev/null || true)"
if [[ "$REQUIRE_SEPARATE_BACKUP" == "true" ]]; then
  if [[ -z "$bak_fs" || "$bak_fs" == "$arc_fs" ]]; then
    err "Backup root $BACKUP_ROOT is on the SAME filesystem as the archive (or not mounted)."
    err "Mount your backup target (external drive or tailnet share) at $BACKUP_ROOT first, or set"
    err "REQUIRE_SEPARATE_BACKUP=false in /etc/archive-ingest.conf for a deliberate same-disk copy."
    exit 1
  fi
fi

note "Measuring the archive (can take a moment on large drives)..."
src_bytes="$(du -sb --exclude='lost+found' --exclude='.recoll' --exclude='.plocate.db' --exclude='.derived' "$ARCHIVE_ROOT" 2>/dev/null | cut -f1)"; src_bytes="${src_bytes:-0}"
avail="$(df -PB1 "$BACKUP_ROOT" | awk 'NR==2{print $4}')"; avail="${avail:-0}"
floor=$(( MIN_FREE_GIB * 1024 * 1024 * 1024 ))
echo "Archive size: $(h "$src_bytes")    Backup free: $(h "$avail")    (floor: ${MIN_FREE_GIB} GiB)"
if (( avail < floor )); then
  err "Backup volume has less than the ${MIN_FREE_GIB} GiB free floor. Free space and retry."
  exit 1
fi
(( avail < src_bytes )) && warn "Backup free space is less than the full archive size; a first full backup may not fit."

if [[ -t 0 ]]; then
  read -rp "Back up ${ARCHIVE_ROOT} -> ${BACKUP_ROOT} now (additive, no deletions)? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] || { echo "Cancelled."; exit 0; }
fi

logf="${BACKUP_ROOT}/.archive-backup.$(date +%Y%m%d-%H%M%S).log"
# Pick rsync flags by destination type. SMB/CIFS can't store Unix permissions, ownership, ACLs or
# xattrs, so -aHAX would error there; on CIFS copy contents + timestamps (and symlinks when the
# share is mounted with mfsymlinks). The SHA-256 manifest check below is authoritative either way.
dest_fstype="$(findmnt -no FSTYPE -T "$BACKUP_ROOT" 2>/dev/null || echo unknown)"
if [[ "$dest_fstype" == cifs || "$dest_fstype" == smb3 ]]; then
  rsync_flags=(-rlt --modify-window=2)
  note "Backup target is ${dest_fstype}: copying contents + timestamps (SMB can't hold Unix metadata)."
else
  rsync_flags=(-aHAX)
fi
# The 'verified' marker means the LAST backup passed the checksum check. Clear it now and only
# re-write it after verification succeeds below — so a failed/interrupted run never looks good.
rm -f "$BACKUP_ROOT/.archive-backup.verified" 2>/dev/null || true
note "Copying (rsync, additive)..." | tee "$logf"
set +e
# --delete is intentionally NOT used: the backup never loses data; index dirs are rebuildable/excluded.
rsync "${rsync_flags[@]}" --info=progress2 --exclude='lost+found' --exclude='.recoll' --exclude='.plocate.db' --exclude='.derived' --exclude='.archive-backup.*.log' \
  "$ARCHIVE_ROOT"/ "$BACKUP_ROOT"/ 2>&1 | tee -a "$logf"
rc=${PIPESTATUS[0]}
# Keep errexit OFF here (this script's header is 'set -uo pipefail', not -e, and it checks every exit
# status explicitly). Re-enabling -e would make the best-effort app-data backup below abort the WHOLE
# run when its rsync returns 23/24 on CIFS — exactly the case the design says we must tolerate.
set +e
# On CIFS, rc 23 (some attributes not transferred) is expected and non-fatal — the manifest check is
# the real gate. On other filesystems, only 0 and 24 are acceptable.
if [[ "$dest_fstype" == cifs || "$dest_fstype" == smb3 ]]; then
  [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]] && { err "rsync exit $rc — backup may be incomplete. See $logf."; exit 1; }
  [[ $rc -eq 23 ]] && warn "rsync 23 on SMB: some attributes weren't copied (expected; contents are verified next)."
else
  [[ $rc -ne 0 && $rc -ne 24 ]] && { err "rsync exit $rc — backup may be incomplete. See $logf. NOT marking verified."; exit 1; }
fi
[[ $rc -eq 24 ]] && warn "rsync 24: some files vanished during copy (usually harmless for a static archive)."

# Re-verify every manifest at the DESTINATION: proves the backup is byte-for-byte faithful.
note "Verifying the backup against each copy's SHA256SUMS manifest..."
vrc=0; checked=0
while IFS= read -r m; do
  d="$(dirname "$m")"; checked=$((checked+1))
  if ( cd "$d" && sha256sum -c --quiet SHA256SUMS ); then
    ok "  OK: ${d#"$BACKUP_ROOT"/}"
  else
    err "  FAILED: $d — backup copy does not match its manifest"; vrc=1
  fi
done < <(find "$BACKUP_ROOT/incoming" -mindepth 2 -name SHA256SUMS 2>/dev/null | sort)

# Completeness, not just self-consistency: "verified" must mean every SOURCE copy is present AND
# verifiable at the destination — otherwise a copy (or just its manifest) that never transferred
# would be invisible to the loop above and the backup would still be blessed. So also compare the
# source copy count, and flag any destination copy folder that arrived WITHOUT a manifest.
src_copies="$(find "$ARCHIVE_ROOT/incoming" -mindepth 2 -name SHA256SUMS 2>/dev/null | wc -l)"
dest_nomanifest="$(find "$BACKUP_ROOT/incoming" -mindepth 2 -maxdepth 2 -type d \
  \! -exec test -e '{}/SHA256SUMS' \; -print 2>/dev/null | wc -l)"

if (( checked == 0 && src_copies == 0 )); then
  warn "No SHA256SUMS manifests found at the destination to verify (nothing ingested yet?)."
elif (( vrc != 0 )); then
  err "One or more backed-up copies FAILED verification. Re-run the backup; do not trust it yet."
  exit 1
elif (( checked < src_copies )); then
  err "Backup INCOMPLETE: ${src_copies} verified copy(ies) in the archive but only ${checked} verifiable at the backup."
  err "A copy (or its manifest) did not transfer. Re-run the backup; NOT marking it verified."
  exit 1
elif (( dest_nomanifest > 0 )); then
  err "Backup has ${dest_nomanifest} copy folder(s) with NO manifest — unverifiable. Re-run; NOT marking verified."
  exit 1
else
  ok "Backup verified: $checked copy(ies) match their manifests (all ${src_copies} archive copies present)."
  printf '%s  verified %s of %s copy(ies)\n' "$(date -Is)" "$checked" "$src_copies" > "$BACKUP_ROOT/.archive-backup.verified" 2>/dev/null || true
fi

# The archive itself is now safely backed up and verified. Additionally fold in the family apps'
# own data (best-effort) — this can WARN but never marks the archive backup above as failed.
backup_apps

echo "Backup log: $logf"
SCRIPT
sudo chmod +x /usr/local/bin/archive-backup

info "writing archive-storage"
sudo tee /usr/local/bin/archive-storage >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-storage — show the storage layout/health and (optionally) attach the archive and backup
# volumes via /etc/fstab safely. It NEVER formats or erases anything, always uses 'nofail' (a
# missing drive can never block boot), backs up /etc/fstab, validates it, and rolls back on error.
#
#   archive-storage [status]     show layout, free space, caps, backup state (default)
#   archive-storage attach-archive   guided: mount a disk at ARCHIVE_ROOT (by UUID, nofail)
#   archive-storage attach-backup    guided: mount a disk or tailnet share at BACKUP_ROOT
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
MAX_ARCHIVE_GIB="${MAX_ARCHIVE_GIB:-1800}"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

is_sep_mount() { [[ "$(findmnt -no TARGET -T "$1" 2>/dev/null)" == "$1" ]]; }   # path is its own mountpoint
fstab_backup() { sudo cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"; }

# ---- status ----------------------------------------------------------------------------------
show_status() {
  note "Storage layout"
  printf '  archive root : %s\n' "$ARCHIVE_ROOT"
  printf '  backup root  : %s\n' "$BACKUP_ROOT"
  printf '  soft cap     : %s GiB (MAX_ARCHIVE_GIB)\n\n' "$MAX_ARCHIVE_GIB"

  local used_b used_g
  if [[ -d "$ARCHIVE_ROOT" ]]; then
    if is_sep_mount "$ARCHIVE_ROOT"; then ok "archive is on its own mounted volume:"; else warn "archive is NOT a separate mount (it is on the OS disk):"; fi
    df -h "$ARCHIVE_ROOT" | sed 's/^/    /'
    used_b="$(du -sb --exclude='.recoll' --exclude='.plocate.db' --exclude='.derived' "$ARCHIVE_ROOT" 2>/dev/null | cut -f1)"; used_b="${used_b:-0}"
    used_g=$(( used_b / 1024 / 1024 / 1024 ))
    printf '    archive data: %s GiB used of %s GiB cap\n' "$used_g" "$MAX_ARCHIVE_GIB"
    if (( used_g >= MAX_ARCHIVE_GIB )); then err "    OVER the soft cap — stop ingesting or raise MAX_ARCHIVE_GIB / add storage."
    elif (( used_g * 10 >= MAX_ARCHIVE_GIB * 9 )); then warn "    within 10% of the soft cap."; fi
  else
    warn "archive root does not exist yet: $ARCHIVE_ROOT"
  fi
  echo
  if [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
    ok "backup is on its own mounted volume:"; df -h "$BACKUP_ROOT" | sed 's/^/    /'
    local last; last="$(find "$BACKUP_ROOT" -maxdepth 1 -name '.archive-backup.*.log' 2>/dev/null | sort | tail -1)"
    if [[ -n "$last" ]]; then printf '    last backup log: %s\n' "$last"; else warn "    no backup has run yet (use: archive-backup)"; fi
  else
    warn "backup root is not a separate mounted volume: $BACKUP_ROOT (use: archive-storage attach-backup)"
  fi
  echo; note "Block devices"; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null | sed 's/^/  /'
}

# ---- helpers for attach ----------------------------------------------------------------------
disk_is_system() { local mp; while IFS= read -r mp; do case "$mp" in /|/boot|/boot/efi|/boot/*|"[SWAP]") return 0 ;; esac; done < <(lsblk -nro MOUNTPOINT "$1" 2>/dev/null); return 1; }
base_disk_of()   { local pk; pk="$(lsblk -no PKNAME "$1" 2>/dev/null | head -1 || true)"; [[ -n "$pk" ]] && printf '/dev/%s\n' "$pk" || printf '%s\n' "$1"; }

pick_partition() {  # echoes a chosen /dev/... partition that has a filesystem, or returns 1
  local -a devs=() rows=(); local name size fstype label type dev base
  while IFS=$'\t' read -r name size fstype label type; do
    [[ "$type" == "part" || "$type" == "disk" ]] || continue
    [[ -n "$fstype" && "$fstype" != "swap" ]] || continue
    dev="/dev/$name"; base="$(base_disk_of "$dev")"
    disk_is_system "$base" && continue
    devs+=("$dev"); rows+=("$(printf '%-14s %-8s %-9s %s' "$dev" "$size" "$fstype" "${label:--}")")
  done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL,TYPE)
  if [[ ${#devs[@]} -eq 0 ]]; then err "No non-system partitions with a filesystem found."; err "If the drive is blank, format it yourself first (this tool never formats)."; return 1; fi
  printf '%sPick a volume:%s\n' "$c_cyn" "$c_rst" >&2
  local i; for i in "${!devs[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${rows[$i]}" >&2; done
  printf '   q) cancel\n' >&2
  local c; read -rp "Number: " c; [[ "$c" == q* ]] && return 1
  if ! { [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#devs[@]} )); }; then err "Invalid choice."; return 1; fi
  printf '%s\n' "${devs[$((c-1))]}"
}

# Append an fstab line safely: back up, write, validate, mount, roll back on any failure.
apply_fstab_line() {  # $1 = mountpoint  $2 = fstab line
  local mp="$1" line="$2" bak
  if grep -qE "[[:space:]]${mp}[[:space:]]" /etc/fstab; then
    err "An /etc/fstab entry for $mp already exists. Edit it by hand if you want to change it."; return 1
  fi
  sudo mkdir -p "$mp"
  bak="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"; sudo cp -a /etc/fstab "$bak"
  printf '\n# Added by archive-storage on %s\n%s\n' "$(date -Is)" "$line" | sudo tee -a /etc/fstab >/dev/null
  echo "Proposed entry:"; printf '  %s\n' "$line"
  if ! sudo findmnt --verify --fstab >/dev/null 2>&1; then
    warn "findmnt reports /etc/fstab problems; rolling back."; sudo cp -a "$bak" /etc/fstab; return 1
  fi
  sudo systemctl daemon-reload 2>/dev/null || true
  if sudo mount "$mp" 2>/dev/null && mountpoint -q "$mp"; then
    ok "Mounted $mp. fstab backup saved at $bak (entry uses 'nofail', so a missing drive won't block boot)."
  else
    err "Could not mount $mp. Rolling back the fstab change (backup at $bak)."; sudo cp -a "$bak" /etc/fstab
    sudo systemctl daemon-reload 2>/dev/null || true; return 1
  fi
}

attach_archive() {
  command -v blkid >/dev/null 2>&1 || { err "blkid not found."; return 1; }
  note "Attach a disk as the archive volume at: $ARCHIVE_ROOT"
  is_sep_mount "$ARCHIVE_ROOT" && { warn "$ARCHIVE_ROOT is already a separate mount. Nothing to do."; return 0; }
  local dev; dev="$(pick_partition)" || return 1
  local uuid fstype; uuid="$(sudo blkid -s UUID -o value "$dev")"; fstype="$(sudo blkid -s TYPE -o value "$dev")"
  [[ -n "$uuid" && -n "$fstype" ]] || { err "Could not read UUID/type of $dev."; return 1; }
  warn "About to mount $dev ($fstype, UUID=$uuid) at $ARCHIVE_ROOT. Existing data on the drive is kept."
  read -rp "Proceed? [y/N] " yn; [[ "$yn" =~ ^[Yy] ]] || { echo "Cancelled."; return 0; }
  apply_fstab_line "$ARCHIVE_ROOT" "UUID=${uuid} ${ARCHIVE_ROOT} ${fstype} defaults,nofail,x-systemd.device-timeout=10s 0 2"
}

attach_backup() {
  note "Attach the backup target at: $BACKUP_ROOT"
  echo "  1) Local disk (external drive)"
  echo "  2) Network share over Tailscale — NFS  (server:/export)"
  echo "  3) Network share over Tailscale — SMB/CIFS  (//server/share)"
  read -rp "Type [1/2/3, or q]: " t
  case "$t" in
    1) local dev uuid fstype; dev="$(pick_partition)" || return 1
       uuid="$(sudo blkid -s UUID -o value "$dev")"; fstype="$(sudo blkid -s TYPE -o value "$dev")"
       [[ -n "$uuid" && -n "$fstype" ]] || { err "Could not read UUID/type of $dev."; return 1; }
       apply_fstab_line "$BACKUP_ROOT" "UUID=${uuid} ${BACKUP_ROOT} ${fstype} defaults,nofail,x-systemd.device-timeout=10s 0 2" ;;
    2) read -rp "NFS export (e.g. 100.x.y.z:/tank/archive-backup): " exp
       [[ -n "$exp" ]] || { err "No export given."; return 1; }
       apply_fstab_line "$BACKUP_ROOT" "${exp} ${BACKUP_ROOT} nfs nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=600 0 0" ;;
    3) read -rp "SMB share (e.g. //100.x.y.z/archive-backup): " unc
       [[ -n "$unc" ]] || { err "No share given."; return 1; }
       read -rp "SMB username: " smbu; read -rsp "SMB password: " smbp; echo
       local cred=/etc/archive-backup.cred
       # Create the secret already-private (0600) so it is never world-readable, even briefly; tee
       # truncates the content but leaves the mode intact, so there is no chmod race.
       sudo install -m 0600 /dev/null "$cred"
       printf 'username=%s\npassword=%s\n' "$smbu" "$smbp" | sudo tee "$cred" >/dev/null
       unset smbu smbp
       # If the mount fails, apply_fstab_line rolls back fstab — also remove the password file it
       # would otherwise leave behind (a root-only secret with no entry referencing it).
       if ! apply_fstab_line "$BACKUP_ROOT" "${unc} ${BACKUP_ROOT} cifs credentials=${cred},nofail,_netdev,uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755,mfsymlinks 0 0"; then
         sudo rm -f "$cred"; err "Mount failed — removed the saved credentials file (${cred}); nothing left half-applied."; return 1
       fi ;;
    q|Q) return 0 ;;
    *) err "Invalid choice."; return 1 ;;
  esac
}

case "${1:-status}" in
  status)         show_status ;;
  attach-archive) attach_archive ;;
  attach-backup)  attach_backup ;;
  -h|--help|help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) err "Unknown command: $1"; echo "Try: archive-storage [status|attach-archive|attach-backup]"; exit 2 ;;
esac
SCRIPT
sudo chmod +x /usr/local/bin/archive-storage

log "Creating the backup mountpoint"
sudo mkdir -p "$BACKUP_ROOT"

log "Installing the login health banner (/etc/update-motd.d)"
# A fast, read-only at-a-glance health line shown on every SSH login, so disk-space / soft-cap /
# backup-freshness problems surface WITHOUT having to run archive-doctor. df/stat/findmnt only
# (never du), with a timeout around the backup share so a stale mount can't slow a login.
sudo mkdir -p /etc/update-motd.d
sudo tee /etc/update-motd.d/50-memorial-archive >/dev/null <<'MOTD'
#!/usr/bin/env bash
# 50-memorial-archive — at-a-glance archive health at login. Installed by archive-storage-setup.sh.
# READ-ONLY and fast (df/stat/findmnt only, never du) so it never slows a login. Remove it via the
# manage.sh Uninstall, or:  sudo rm -f /etc/update-motd.d/50-memorial-archive
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf 2>/dev/null || true
fi
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
MAX_ARCHIVE_GIB="${MAX_ARCHIVE_GIB:-1800}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
BACKUP_STALE_DAYS="${BACKUP_STALE_DAYS:-30}"
if [[ -t 1 ]]; then r=$'\033[1;31m'; g=$'\033[1;32m'; y=$'\033[1;33m'; c=$'\033[0;36m'; d=$'\033[2m'; z=$'\033[0m'
else r=''; g=''; y=''; c=''; d=''; z=''; fi
h(){ numfmt --to=iec "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
is_mount(){ [[ "$(findmnt -no TARGET -T "$1" 2>/dev/null)" == "$1" ]]; }

printf '\n%sMemorial Archive%s — health\n' "$c" "$z"

# Archive volume: lead with free space (exact); flag soft-cap proximity. df only — instant.
if is_mount "$ARCHIVE_ROOT"; then
  total=0; used=0; avail=0
  read -r total used avail < <(df -PB1 "$ARCHIVE_ROOT" 2>/dev/null | awk 'NR==2{print $2, $3, $4}')
  cap=$(( MAX_ARCHIVE_GIB * 1024*1024*1024 )); floor=$(( MIN_FREE_GIB * 1024*1024*1024 ))
  if   (( avail < floor ));    then printf '  %s✗ archive: only %s free — under the %s GiB floor%s\n' "$r" "$(h "$avail")" "$MIN_FREE_GIB" "$z"
  elif (( used >= cap ));      then printf '  %s✗ archive: OVER the %s GiB soft cap (%s free) — add storage or raise MAX_ARCHIVE_GIB%s\n' "$r" "$MAX_ARCHIVE_GIB" "$(h "$avail")" "$z"
  elif (( used*10 >= cap*9 )); then printf '  %s! archive: within 10%% of the %s GiB soft cap (%s free)%s\n' "$y" "$MAX_ARCHIVE_GIB" "$(h "$avail")" "$z"
  else                              printf '  %s✓%s archive: %s free of %s (soft cap %s GiB)\n' "$g" "$z" "$(h "$avail")" "$(h "$total")" "$MAX_ARCHIVE_GIB"
  fi
else
  printf '  %s✗ archive: NOT mounted at %s%s\n' "$r" "$ARCHIVE_ROOT" "$z"
fi

# Backup freshness: findmnt (safe — reads the kernel mount table) to detect the mount, then a
# timeout'd stat of the marker so a stale/unreachable share can never hang the login.
if is_mount "$BACKUP_ROOT"; then
  mts="$(timeout 3 stat -c %Y "$BACKUP_ROOT/.archive-backup.verified" 2>/dev/null)"
  if [[ -n "${mts:-}" ]]; then
    age=$(( ( $(date +%s) - mts ) / 86400 ))
    if (( age > BACKUP_STALE_DAYS )); then printf '  %s! backup: last verified %s day(s) ago (> %s)%s\n' "$y" "$age" "$BACKUP_STALE_DAYS" "$z"
    else printf '  %s✓%s backup: verified %s day(s) ago\n' "$g" "$z" "$age"; fi
  else
    printf '  %s! backup: no verified backup yet%s\n' "$y" "$z"
  fi
fi
printf '%s  full check: archive-doctor.sh%s\n' "$d" "$z"
MOTD
sudo chmod +x /etc/update-motd.d/50-memorial-archive
info "Login banner installed — shows on SSH login. Preview now: run-parts /etc/update-motd.d"

log "Storage tools installed."
cat <<EOF
    See the layout and health any time:
      archive-storage

    Attach your volumes (guided, safe — 'nofail', backs up & validates fstab, never formats):
      archive-storage attach-archive    # mount the 2 TB external as ${ARCHIVE_ROOT}
      archive-storage attach-backup     # mount an external drive OR a Tailscale NFS/SMB share at ${BACKUP_ROOT}

    Run a verified backup (additive; re-checks every checksum at the destination):
      archive-backup
      # If Immich/Paperless are installed, this ALSO dumps their own data (Paperless documents +
      # tags via its exporter; Immich database + uploaded originals) under ${BACKUP_ROOT}/apps,
      # each with a RESTORE.txt. A problem there only warns — it never fails the archive backup.

    Optional settings in /etc/archive-ingest.conf: BACKUP_ROOT, MAX_ARCHIVE_GIB (soft cap, default
    1800), REQUIRE_SEPARATE_BACKUP (default true — refuse to "back up" onto the same disk),
    BACKUP_APPS (default true — set false to skip the Immich/Paperless/Docmost app-data backup).
    Tip: attach the tailnet share first ('archive-storage attach-backup'), then run 'archive-backup'.
EOF
