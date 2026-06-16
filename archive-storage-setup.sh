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
sudo apt-get update -y
sudo apt-get install -y nfs-common cifs-utils rsync

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

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
h() { numfmt --to=iec "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

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
src_bytes="$(du -sb --exclude='.recoll' --exclude='.plocate.db' "$ARCHIVE_ROOT" 2>/dev/null | cut -f1)"; src_bytes="${src_bytes:-0}"
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
note "Copying (rsync, additive)..." | tee "$logf"
set +e
# --delete is intentionally NOT used: the backup never loses data. The index dirs are rebuildable
# and excluded. -aHAX preserves the same metadata as the ingest copies.
rsync -aHAX --info=progress2 --exclude='.recoll' --exclude='.plocate.db' --exclude='.archive-backup.*.log' \
  "$ARCHIVE_ROOT"/ "$BACKUP_ROOT"/ 2>&1 | tee -a "$logf"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 && $rc -ne 24 ]]; then
  err "rsync exit $rc — backup may be incomplete. See $logf. NOT marking this backup as verified."
  exit 1
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

if [[ $checked -eq 0 ]]; then
  warn "No SHA256SUMS manifests found at the destination to verify (nothing ingested yet?)."
elif [[ $vrc -eq 0 ]]; then
  ok "Backup verified: $checked copies match their manifests."
else
  err "One or more backed-up copies FAILED verification. Re-run the backup; do not trust it yet."
  exit 1
fi
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
    used_b="$(du -sb --exclude='.recoll' --exclude='.plocate.db' "$ARCHIVE_ROOT" 2>/dev/null | cut -f1)"; used_b="${used_b:-0}"
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
       printf 'username=%s\npassword=%s\n' "$smbu" "$smbp" | sudo tee "$cred" >/dev/null
       sudo chmod 600 "$cred"
       apply_fstab_line "$BACKUP_ROOT" "${unc} ${BACKUP_ROOT} cifs credentials=${cred},nofail,_netdev,uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755 0 0" ;;
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

log "Storage tools installed."
cat <<EOF
    See the layout and health any time:
      archive-storage

    Attach your volumes (guided, safe — 'nofail', backs up & validates fstab, never formats):
      archive-storage attach-archive    # mount the 2 TB external as ${ARCHIVE_ROOT}
      archive-storage attach-backup     # mount an external drive OR a Tailscale NFS/SMB share at ${BACKUP_ROOT}

    Run a verified backup (additive; re-checks every checksum at the destination):
      archive-backup

    Optional settings in /etc/archive-ingest.conf: BACKUP_ROOT, MAX_ARCHIVE_GIB (soft cap, default
    1800), REQUIRE_SEPARATE_BACKUP (default true — refuse to "back up" onto the same disk).
    Tip: attach the tailnet share first ('archive-storage attach-backup'), then run 'archive-backup'.
EOF
