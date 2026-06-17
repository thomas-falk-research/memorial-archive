#!/usr/bin/env bash
#
# archive-ingest-setup.sh — Phase 1 (hardened) of a digital-archive ingestion server.
#
# Lets this host READ arbitrary source media and network shares WITHOUT writing to the source,
# and copy into a pristine, checksum-verified archival master. Installs tooling and four commands:
#
#   safe-mount      write-block a device at the block layer, then mount READ-ONLY.
#                   Refuses the system disk. Run with no args for a guided picker.
#   ingest-verify   verified copy into the archive (mount + free-space + completeness + fixity).
#   archive-verify  re-check a finished copy against its checksum manifest (detect bit-rot).
#   archive         a guided menu (see -> mount -> copy -> verify -> eject) for non-experts.
#
# Settings live in /etc/archive-ingest.conf (written by this installer, re-read by every command),
# so you can retarget paths/volumes by editing that file with no reinstall. Per-user overrides may
# go in ${XDG_CONFIG_HOME:-~/.config}/archive-ingest.conf.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-ingest-setup.sh`).
#
set -euo pipefail
umask 022

# ---- Configuration (defaults; overridden by an existing config or by --config) ---------------
INSTALL_APFS=true
ARCHIVE_ROOT="/srv/archive"     # where verified copies are written (point at your archive volume)
INGEST_MNT="/mnt/ingest"        # where source media is mounted read-only
REQUIRE_MOUNTED_DEST="true"     # refuse to ingest unless ARCHIVE_ROOT is a separate mounted volume
MIN_FREE_GIB="10"               # keep at least this many GiB free on the archive after a copy
CONFIG_SYS="/etc/archive-ingest.conf"
CONFIG_FILE=""                  # optional --config path to seed the settings

# Package sets, defined once and reused by both the plan summary and the installer.
CORE_PKGS=(
  ntfs-3g exfatprogs dosfstools btrfs-progs xfsprogs f2fs-tools udftools e2fsprogs
  lvm2 mdadm cryptsetup zfsutils-linux
  fuse3
  cifs-utils smbclient nfs-common
  avahi-utils nmap
  gddrescue testdisk
  rhash libimage-exiftool-perl jdupes rdfind convmv rsync
)
BEST_EFFORT_PKGS=( hfsprogs hashdeep dislocker davfs2 )
SKIPPED=()
STEP=0; STEP_TOTAL=7

# ---- Argument parsing (before logging, so --help never creates a log file) -------------------
ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--config FILE] [--help|-h]
  --yes, -y       skip the confirmation prompt (for unattended runs)
  --config FILE   seed settings from FILE (installed to ${CONFIG_SYS} for all commands)
  --help, -h      show this help and exit
Settings (ARCHIVE_ROOT, INGEST_MNT, REQUIRE_MOUNTED_DEST, MIN_FREE_GIB) are read from
${CONFIG_SYS} at run time; edit that file to retarget without reinstalling.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=true ;;
    -c|--config) CONFIG_FILE="${2:?--config needs a file path}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# Seed effective settings: an existing system config, then per-user, then --config (highest).
if [[ -n "${CONFIG_FILE}" && ! -r "${CONFIG_FILE}" ]]; then
  printf 'Config file not readable: %s\n' "${CONFIG_FILE}" >&2; exit 2
fi
for _cfg in "${CONFIG_SYS}" "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf" "${CONFIG_FILE}"; do
  [[ -n "${_cfg}" && -r "${_cfg}" ]] || continue
  # shellcheck source=/dev/null
  . "${_cfg}"
done

# ---- Logging: concise on screen, full detail (incl. a command trace) to a log file -----------
LOGFILE="${LOGFILE:-${HOME}/archive-ingest-setup.$(date +%Y%m%d-%H%M%S).log}"
if ! : >"$LOGFILE" 2>/dev/null; then
  LOGFILE="/tmp/archive-ingest-setup.$(date +%Y%m%d-%H%M%S).log"; : >"$LOGFILE"
fi
exec {XTRACE_FD}>>"$LOGFILE"                 # send the xtrace stream to the log, not the screen
BASH_XTRACEFD=$XTRACE_FD
# shellcheck disable=SC2016  # PS4 is meant to expand at trace time, not now
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
set -x

trap 'rc=$?; set +x; printf "\n\033[1;31mERROR\033[0m: step failed at line %s (exit %s). Full log: %s\n" "$LINENO" "$rc" "$LOGFILE" >&2' ERR

tolog() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOGFILE"; }
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; tolog "==> $*"; }
step() { STEP=$((STEP+1)); printf '\n\033[1;34m[%d/%d]\033[0m %s\n' "$STEP" "$STEP_TOTAL" "$*"; tolog "[$STEP/$STEP_TOTAL] $*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; tolog "    $*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*" >&2; tolog "WARN: $*"; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; tolog "FATAL: $*"; exit 1; }

# run "Short description" cmd args...  — one progress line on screen; full output to the log.
run() {
  local desc="$1"; shift
  printf '    %s ... ' "$desc"
  local out; out="$(mktemp)"
  if "$@" >"$out" 2>&1; then
    cat "$out" >>"$LOGFILE"; rm -f "$out"
    printf '\033[0;32mdone\033[0m\n'; tolog "OK  : $desc"
  else
    local rc=$?
    cat "$out" >>"$LOGFILE"
    printf '\033[1;31mFAILED (exit %s)\033[0m\n' "$rc"; tolog "FAIL: $desc (exit $rc)"
    printf '    --- last output of the failed step ---\n'
    tail -n 12 "$out" | sed 's/^/    | /'
    printf '    full log: %s\n' "$LOGFILE"
    rm -f "$out"
    return "$rc"
  fi
}

print_plan() {
  printf '    - apt-get update, then install %d packages:\n' "${#CORE_PKGS[@]}"
  printf '        %s\n' "${CORE_PKGS[*]}"
  printf '    - try, skipping any not in this release: %s\n' "${BEST_EFFORT_PKGS[*]}"
  printf '    - install BagIt via pipx (optional)\n'
  if [[ "${INSTALL_APFS}" == "true" ]]; then
    printf '    - build apfs-fuse from source (read-only Apple APFS)\n'
  fi
  printf '    - disable GNOME removable-media auto-mount for %s\n' "$(id -un)"
  printf '    - install commands to /usr/local/bin: safe-mount, ingest-verify, archive-verify, archive\n'
  printf '    - write settings to %s (edit later to retarget; re-read by every command)\n' "${CONFIG_SYS}"
  printf '    - create %s and %s\n' "${ARCHIVE_ROOT}" "${INGEST_MNT}"
  printf '    - write a full log to: %s\n' "${LOGFILE}"
}

# ---- Preflight -------------------------------------------------------------------------------
[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Targeting Ubuntu; detected ID='${ID:-unknown}'."
export DEBIAN_FRONTEND=noninteractive

# ---- Plan + approval (the system has not been changed at this point) -------------------------
log "This installer will make the following changes, using sudo:"
print_plan
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Starting — concise progress below; full detail in ${LOGFILE}"
info "You may be prompted once for your sudo password."
sudo -v

# ----------------------------------------------------------------------------------------------
# 1. Core packages (must-have).
# ----------------------------------------------------------------------------------------------
step "Installing core packages (filesystems, network shares, recovery, integrity)"
run "Updating package lists" sudo DEBIAN_FRONTEND=noninteractive apt-get update
run "Installing ${#CORE_PKGS[@]} core packages (can take a few minutes)" \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${CORE_PKGS[@]}"

# ----------------------------------------------------------------------------------------------
# 2. Best-effort extras (names vary by release; missing ones are reported, not fatal).
# ----------------------------------------------------------------------------------------------
step "Installing best-effort extras (skipped individually if not in this release)"
for pkg in "${BEST_EFFORT_PKGS[@]}"; do
  # shellcheck disable=SC2024  # log is user-owned; the redirect is meant to run as us, not root
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"$LOGFILE" 2>&1; then info "installed: $pkg"
  else warn "unavailable on this release: $pkg (skipped)"; SKIPPED+=("$pkg"); fi
done

# ----------------------------------------------------------------------------------------------
# 3. BagIt (archival packaging) via pipx, if available.
# ----------------------------------------------------------------------------------------------
step "Installing BagIt (optional preservation packaging)"
# shellcheck disable=SC2024  # log is user-owned; the redirect is meant to run as us, not root
if command -v pipx >/dev/null 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pipx >>"$LOGFILE" 2>&1; then
  if pipx install bagit >>"$LOGFILE" 2>&1; then info "installed: bagit (CLI: bagit.py)"
  else warn "bagit via pipx failed (optional)"; SKIPPED+=("bagit"); fi
else
  warn "pipx unavailable; skipped bagit (optional)"; SKIPPED+=("bagit")
fi

# ----------------------------------------------------------------------------------------------
# 4. APFS read-only support (build apfs-fuse). Optional and non-fatal.
# ----------------------------------------------------------------------------------------------
install_apfs() {
  command -v apfs-fuse >/dev/null 2>&1 && { info "apfs-fuse already installed."; return 0; }
  run "Installing build dependencies" \
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cmake g++ git libfuse3-dev libbz2-dev zlib1g-dev libattr1-dev || return 1
  local d; d="$(mktemp -d)"
  run "Cloning apfs-fuse source" \
      git clone --recursive --depth 1 https://github.com/sgan81/apfs-fuse "${d}/apfs-fuse" || { rm -rf "${d}"; return 1; }
  # CMake 4 (Ubuntu 26.04) dropped support for apfs-fuse's old cmake_minimum_required; the policy
  # floor lets its CMakeLists configure anyway (CMake's own suggested workaround).
  run "Compiling apfs-fuse (1-2 minutes)" \
      bash -c "cd '${d}/apfs-fuse' && mkdir build && cd build && cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 .. && make -j\"\$(nproc)\" && sudo make install" \
      || { rm -rf "${d}"; return 1; }
  rm -rf "${d}"
  info "Built apfs-fuse (upstream is unversioned; record the commit if you need reproducibility)."
}
if [[ "${INSTALL_APFS}" == "true" ]]; then
  step "Building apfs-fuse (read-only Apple APFS support)"
  install_apfs || warn "apfs-fuse build failed; continuing without APFS read support (see ${LOGFILE})."
else
  step "Apple APFS support (skipped: INSTALL_APFS=false)"
fi

# ----------------------------------------------------------------------------------------------
# 5. Disable desktop auto-mount so source media is never auto-touched (best-effort).
# ----------------------------------------------------------------------------------------------
step "Disabling desktop auto-mount of removable media"
if command -v gsettings >/dev/null 2>&1 \
   && gsettings set org.gnome.desktop.media-handling automount false 2>/dev/null \
   && gsettings set org.gnome.desktop.media-handling automount-open false 2>/dev/null \
   && gsettings set org.gnome.desktop.media-handling autorun-never true 2>/dev/null; then
  info "Auto-mount disabled for $(id -un)."
else
  warn "Could not set GNOME auto-mount keys (headless or no active session)."
  warn "If this is a desktop session, disable auto-mount manually so drives are never"
  warn "auto-mounted read-write before you write-block them."
fi

# System-wide belt-and-suspenders: tell udisks not to auto-mount hot-plugged USB filesystems, so
# no desktop session can mount source media read-write before safe-mount engages the write-block.
# This only suppresses *automatic* mounting — it does NOT write-block — so the archive/backup
# volumes you mount explicitly (via fstab) are unaffected.
info "installing udev rule to suppress auto-mount of USB media (UDISKS_AUTO=0)"
sudo tee /etc/udev/rules.d/99-archive-no-automount.rules >/dev/null <<'RULE'
# Installed by archive-ingest-setup.sh — do not auto-mount hot-plugged USB filesystems.
# safe-mount mounts source media read-only behind a block-layer write-block instead.
SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", ENV{UDISKS_AUTO}="0"
RULE
sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger --subsystem-match=block 2>/dev/null || true

# ----------------------------------------------------------------------------------------------
# 6. safe-mount
# ----------------------------------------------------------------------------------------------
step "Installing commands to /usr/local/bin"
info "writing safe-mount"
sudo tee /usr/local/bin/safe-mount >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# safe-mount [DEVICE] [LABEL]
# Mount source media READ-ONLY behind a block-layer write-block. Refuses the system disk.
# With no DEVICE, lists non-system devices and lets you pick one.
set -euo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  if [[ -r "$_cfg" ]]; then
    # shellcheck source=/dev/null
    . "$_cfg" || true
  fi
done
INGEST_MNT="${INGEST_MNT:-/mnt/ingest}"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

for _t in lsblk blockdev mount findmnt blkid mountpoint; do
  command -v "$_t" >/dev/null 2>&1 || { err "Required tool not found: $_t. Run the setup script first."; exit 1; }
done

base_disk_of() {  # whole disk backing a partition (sda from sda1); self if already a disk
  local d="$1" pk
  pk="$(lsblk -no PKNAME "$d" 2>/dev/null | head -1 || true)"
  if [[ -n "$pk" ]]; then printf '/dev/%s\n' "$pk"; else printf '%s\n' "$d"; fi
}

disk_is_system() {  # does this whole disk host /, /boot*, or swap anywhere in its tree?
  local disk="$1" mp
  while IFS= read -r mp; do
    case "$mp" in /|/boot|/boot/efi|/boot/*|"[SWAP]") return 0 ;; esac
  done < <(lsblk -nro MOUNTPOINT "$disk" 2>/dev/null)
  return 1
}

pick_device() {
  local -a devs=() rows=()
  local name size fstype label type dev base nparts
  while IFS=$'\t' read -r name size fstype label type; do
    [[ "$type" == "part" || "$type" == "disk" ]] || continue
    dev="/dev/$name"
    base="$(base_disk_of "$dev")"
    disk_is_system "$base" && continue
    if [[ "$type" == "disk" ]]; then
      nparts="$(lsblk -rno NAME "$dev" 2>/dev/null | tail -n +2 | wc -l)"
      [[ "$nparts" -gt 0 ]] && continue   # list its partitions instead of the bare disk
    fi
    devs+=("$dev")
    rows+=("$(printf '%-14s %-8s %-10s %s' "$dev" "$size" "${fstype:--}" "${label:--}")")
  done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL,TYPE)

  if [[ ${#devs[@]} -eq 0 ]]; then
    err "No non-system source devices found. Plug in the drive and try again." ; return 1
  fi
  printf '%sSelect the source to mount read-only:%s\n' "$c_cyn" "$c_rst" >&2
  local i
  for i in "${!devs[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${rows[$i]}" >&2; done
  printf '   q) cancel\n' >&2
  local choice; read -rp "Number: " choice
  [[ "$choice" == "q" || "$choice" == "Q" ]] && return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#devs[@]} )); then err "Invalid choice."; return 1; fi
  printf '%s\n' "${devs[$((choice-1))]}"
}

dev="${1:-}"; label="${2:-}"
if [[ -z "$dev" ]]; then dev="$(pick_device)" || exit 1; fi
[[ -b "$dev" ]] || { err "Not a block device: $dev"; exit 1; }

base="$(base_disk_of "$dev")"
if disk_is_system "$base"; then
  err "REFUSING: $dev is on the system disk ($base). Never write-block or mount the OS disk."
  exit 1
fi

fstype="$(lsblk -no FSTYPE "$dev" | head -1)"
vlabel="$(lsblk -no LABEL "$dev" | head -1)"
diskinfo="$(lsblk -dno SIZE,MODEL "$base" 2>/dev/null | xargs || true)"
note "Target:     $dev   (disk $base — ${diskinfo:-?})"
note "Filesystem: ${fstype:-unknown}   Volume label: ${vlabel:--}"

if [[ -t 0 ]]; then
  read -rp "Mount this READ-ONLY? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] || { echo "Cancelled."; exit 0; }
fi

# If the desktop already auto-mounted it (possibly read-write), unmount before write-blocking.
existing="$(findmnt -nro TARGET --source "$dev" 2>/dev/null | head -1 || true)"
if [[ -n "$existing" ]]; then
  warn "$dev is already mounted at $existing (possibly read-write auto-mount)."
  warn "Auto-mount may have already written to the source. Unmounting it now."
  sudo umount "$dev" || { err "Could not unmount $dev. Close anything using it and retry."; exit 1; }
fi

# Container types are imported/assembled, not mounted by partition. Guide instead of mounting.
case "$fstype" in
  zfs_member)
    err "ZFS member. Import the pool READ-ONLY:  sudo zpool import -o readonly=on -N <pool>"; exit 2 ;;
  LVM2_member)
    err "LVM physical volume. Activate then safe-mount the LV:  sudo vgchange -a y && lvs"; exit 2 ;;
  linux_raid_member)
    err "md-RAID member. Assemble read-only:  sudo mdadm --assemble --readonly --scan"; exit 2 ;;
  crypto_LUKS)
    err "LUKS volume. Open read-only:  sudo cryptsetup open --readonly $dev unlocked"; exit 2 ;;
esac

if ! sudo blockdev --setro "$base"; then
  err "Could not engage write-block on $base. Refusing to mount (won't risk writing the source)."
  exit 1
fi
if [[ "$(sudo blockdev --getro "$base" 2>/dev/null)" != "1" ]]; then
  err "Write-block reported success but the read-only flag is NOT set on $base. Refusing to mount."
  exit 1
fi
ok "Write-blocked $base (read-only at the block layer, verified)."

name="${label:-${vlabel:-$(blkid -s UUID -o value "$dev" 2>/dev/null || basename "$dev")}}"
name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"
if [[ -z "$name" || "$name" =~ ^\.+$ ]]; then name="$(basename "$dev")"; fi
mnt="${INGEST_MNT}/${name}"
sudo mkdir -p "$mnt"

set +e
case "$fstype" in
  apfs)
    command -v apfs-fuse >/dev/null || { err "apfs-fuse not installed."; exit 1; }
    sudo apfs-fuse -o ro "$dev" "$mnt"; rc=$? ;;
  hfsplus|hfs)
    sudo mount -t hfsplus -o ro,force "$dev" "$mnt"; rc=$? ;;   # 'force' for journaled/dirty HFS+
  ext4|ext3)
    # noload: never replay the journal, so a dirty ext volume mounts read-only instead of being
    # refused — and a journal replay can never write back to the (supposedly read-only) source.
    sudo mount -t "$fstype" -o ro,noload "$dev" "$mnt"; rc=$? ;;
  *)
    sudo mount -o ro "$dev" "$mnt"; rc=$? ;;
esac
set -e
if [[ $rc -ne 0 ]]; then
  err "Mount failed (rc=$rc). The disk stays write-blocked (safe). If the filesystem is dirty,"
  err "image it first:  sudo ddrescue -d /dev/${base##*/} /srv/archive/images/img.dd img.map"
  sudo rmdir "$mnt" 2>/dev/null || true
  exit 1
fi
ok "Mounted $dev (${fstype:-unknown}) READ-ONLY at $mnt"
note "Next:  ingest-verify '$mnt' <a-short-label>"
note "Done:  sudo umount '$mnt'   (apfs: sudo fusermount3 -u '$mnt')"
SCRIPT
sudo chmod +x /usr/local/bin/safe-mount

# ----------------------------------------------------------------------------------------------
# 7. ingest-verify
# ----------------------------------------------------------------------------------------------
info "writing ingest-verify"
sudo tee /usr/local/bin/ingest-verify >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# ingest-verify SOURCE_DIR SOURCE_LABEL
# Verified copy into the archive: space check, completeness check, SHA-256 fixity, provenance.
# A copy stays marked .INCOMPLETE until it fully passes, so a partial master is never trusted.
set -euo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  if [[ -r "$_cfg" ]]; then
    # shellcheck source=/dev/null
    . "$_cfg" || true
  fi
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
REQUIRE_MOUNTED_DEST="${REQUIRE_MOUNTED_DEST:-true}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
h() { numfmt --to=iec "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

for _t in rsync sha256sum numfmt find df du findmnt; do
  command -v "$_t" >/dev/null 2>&1 || { err "Required tool not found: $_t. Run the setup script first."; exit 1; }
done

src="${1:?usage: ingest-verify <source-dir> <source-label>}"
raw="${2:?provide a short source label, e.g. dads-laptop-cdrive}"
[[ -d "$src" ]] || { err "Source directory not found: $src"; exit 1; }

label="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
[[ -n "$label" ]] || { err "Label is empty after sanitizing; use letters/numbers."; exit 1; }
[[ "$label" =~ ^\.+$ ]] && { err "Label cannot be only dots."; exit 1; }
[[ "$label" == "$raw" ]] || note "Using sanitized label: $label"

# Guardrail: refuse to write unless ARCHIVE_ROOT is on a separate mounted volume, so an unmounted
# drive can't cause the archive to land silently on the OS disk. findmnt -T resolves the filesystem
# backing the path; if that is "/", the archive volume is not mounted where it should be.
if [[ "$REQUIRE_MOUNTED_DEST" == "true" ]]; then
  dest_fs="$(findmnt -no TARGET -T "$ARCHIVE_ROOT" 2>/dev/null || echo /)"
  if [[ "$dest_fs" == "/" ]]; then
    err "Archive root $ARCHIVE_ROOT is on the ROOT filesystem, not a separate mounted volume."
    err "The archive drive is probably not mounted. Mount it at $ARCHIVE_ROOT and retry, or set"
    err "REQUIRE_MOUNTED_DEST=false in /etc/archive-ingest.conf for a deliberate single-disk setup."
    exit 1
  fi
fi

note "Scanning source (can take a moment on large drives)..."
src_files="$(find "$src" -type f 2>/dev/null | wc -l)"
src_bytes="$(du -sb "$src" 2>/dev/null | cut -f1)"; src_bytes="${src_bytes:-0}"
if [[ "${src_files:-0}" -eq 0 ]]; then
  err "Source has 0 files: $src"
  err "Is the drive actually mounted there?  Check:  ls -la '$src'"
  exit 1
fi
echo "Source: $src_files files, $(h "$src_bytes")"

dest_parent="${ARCHIVE_ROOT}/incoming/${label}"; mkdir -p "$dest_parent"
avail="$(df -PB1 "$dest_parent" | awk 'NR==2{print $4}')"; avail="${avail:-0}"
floor=$(( MIN_FREE_GIB * 1024 * 1024 * 1024 ))
need=$(( src_bytes + src_bytes/20 + 10*1024*1024 ))   # source + 5% + 10MiB working headroom
if (( avail < need + floor )); then
  err "Not enough free space at $ARCHIVE_ROOT: have $(h "$avail")."
  err "Need ~$(h "$need") for this copy plus a ${MIN_FREE_GIB} GiB floor (= ~$(h "$((need+floor))"))."
  err "Free space on the archive, or lower MIN_FREE_GIB in /etc/archive-ingest.conf."
  exit 1
fi
echo "Destination free: $(h "$avail") (keeping >= ${MIN_FREE_GIB} GiB free) — sufficient."

dest="${dest_parent}/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dest"
marker="${dest}/.INCOMPLETE"; : > "$marker"
logf="${dest}.ingest.log"

if [[ -t 0 ]]; then
  read -rp "Copy $(h "$src_bytes") into $dest ? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] || { echo "Cancelled."; rm -f "$marker"; rmdir "$dest" 2>/dev/null || true; exit 0; }
fi

echo "Copying..." | tee "$logf"
set +e
rsync -aHAX --info=progress2 "$src"/ "$dest"/ 2>&1 | tee -a "$logf"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 && $rc -ne 24 ]]; then
  err "rsync exit $rc — some files could NOT be read/copied. See $logf."
  err "Copy left marked .INCOMPLETE. Likely causes: permissions, or a failing drive (image it"
  err "with ddrescue and ingest the image). Fix and re-run; do not trust this copy."
  exit 1
fi
[[ $rc -eq 24 ]] && warn "rsync 24: some files vanished during copy (usually harmless for static media)."

manifest="${dest}/SHA256SUMS"
( cd "$dest" && find . -type f ! -name 'SHA256SUMS' ! -name '.INCOMPLETE' ! -name 'PROVENANCE.txt' \
    -print0 | sort -z | xargs -0 -r sha256sum ) > "$manifest"
copied="$(wc -l < "$manifest")"
echo "Manifest: $manifest ($copied files)" | tee -a "$logf"
if [[ "$copied" -ne "$src_files" ]]; then
  warn "File-count mismatch: source $src_files vs copied $copied. Investigate before trusting."
fi

echo "Verifying copy against manifest..." | tee -a "$logf"
if ( cd "$dest" && sha256sum -c --quiet SHA256SUMS ); then
  ok "VERIFY OK"
else
  err "VERIFY FAILED — copy left .INCOMPLETE. Re-run from source."; exit 1
fi

cat > "${dest}/PROVENANCE.txt" <<EOF
source_label: ${label}
source_path:  ${src}
ingested_at:  $(date -Is)
ingested_by:  $(id -un)@$(hostname -s)
file_count:   ${copied}
byte_count:   ${src_bytes}
tool:         ingest-verify (rsync -aHAX + sha256)
EOF

rm -f "$marker"
ok "Verified master copy: $dest"
echo "Provenance: ${dest}/PROVENANCE.txt" | tee -a "$logf"
SCRIPT
sudo chmod +x /usr/local/bin/ingest-verify

# ----------------------------------------------------------------------------------------------
# 7b. archive-verify — re-check a finished copy against its checksum manifest (detect bit-rot)
# ----------------------------------------------------------------------------------------------
info "writing archive-verify"
sudo tee /usr/local/bin/archive-verify >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-verify [DIR]
# Re-check a finished ingest against its SHA256SUMS manifest (detects bit-rot or damage).
# With no DIR, checks every completed copy under the archive. Exits non-zero on any mismatch.
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  if [[ -r "$_cfg" ]]; then
    # shellcheck source=/dev/null
    . "$_cfg" || true
  fi
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
command -v sha256sum >/dev/null 2>&1 || { err "sha256sum not found."; exit 1; }

verify_one() {  # $1 = directory containing SHA256SUMS
  local d="$1" out vrc
  [[ -f "$d/SHA256SUMS" ]] || { warn "No manifest in $d (skipping)"; return 0; }
  [[ -f "$d/.INCOMPLETE" ]] && warn "$d is marked .INCOMPLETE (was never fully ingested)"
  printf 'Verifying %s ... ' "$d"
  out="$( cd "$d" && sha256sum -c SHA256SUMS 2>&1 )"; vrc=$?
  if [[ $vrc -eq 0 ]]; then ok "OK"; return 0; fi
  err "FAILED — contents differ from the manifest"
  printf '%s\n' "$out" | grep -vE ': OK$' | head -n 20 | sed 's/^/    /'
  return 1
}

rc=0
if [[ $# -ge 1 ]]; then
  verify_one "$1" || rc=1
else
  base="${ARCHIVE_ROOT}/incoming"
  [[ -d "$base" ]] || { err "No archive found at $base"; exit 1; }
  found=0
  while IFS= read -r m; do
    found=1; verify_one "$(dirname "$m")" || rc=1
  done < <(find "$base" -mindepth 2 -name SHA256SUMS 2>/dev/null | sort)
  [[ $found -eq 1 ]] || warn "No completed ingests found under $base"
fi
if [[ $rc -eq 0 ]]; then ok "All checked copies match their manifests."
else err "One or more copies FAILED verification — restore those from your backup or source."; fi
exit $rc
SCRIPT
sudo chmod +x /usr/local/bin/archive-verify

# ----------------------------------------------------------------------------------------------
# 8. archive — guided menu
# ----------------------------------------------------------------------------------------------
info "writing archive"
sudo tee /usr/local/bin/archive >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive — guided menu over safe-mount / ingest-verify for non-expert operators.
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  if [[ -r "$_cfg" ]]; then
    # shellcheck source=/dev/null
    . "$_cfg" || true
  fi
done
INGEST_MNT="${INGEST_MNT:-/mnt/ingest}"; export INGEST_MNT
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"; export ARCHIVE_ROOT

pause() { read -rp $'\nPress Enter to return to the menu... ' _ || exit 0; }

list_ingest_mounts() {
  local -n out="$1"; out=()
  local d
  for d in "${INGEST_MNT}"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    mountpoint -q "$d" && out+=("$d")
  done
}

choose_mount() {  # prints a chosen mountpoint to stdout, or returns 1
  local -a m; list_ingest_mounts m
  if [[ ${#m[@]} -eq 0 ]]; then echo "No drives are mounted under ${INGEST_MNT}." >&2; return 1; fi
  echo "Mounted drives:" >&2
  local i; for i in "${!m[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${m[$i]}" >&2; done
  local c; read -rp "Number: " c || return 1
  if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > ${#m[@]} )); then echo "Invalid choice." >&2; return 1; fi
  printf '%s\n' "${m[$((c-1))]}"
}

while true; do
  clear 2>/dev/null || true
  cat <<'M'
================ Digital Archive — guided ingestion ================
  1) See what drives are plugged in
  2) Mount a drive safely (read-only)
  3) Copy a mounted drive into the archive (verified)
  4) Safely eject a drive
  5) Show what is already in the archive
  6) Check the archive for damage (re-verify checksums)
  q) Quit
====================================================================
M
  read -rp "Choose: " choice || exit 0
  case "$choice" in
    1) echo; lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINTS; pause ;;
    2) echo; safe-mount || true; pause ;;
    3) echo
       if mp="$(choose_mount)"; then
         def="$(basename "$mp")"
         read -rp "Label for this source [${def}]: " lbl
         ingest-verify "$mp" "${lbl:-$def}" || true
       fi
       pause ;;
    4) echo
       if mp="$(choose_mount)"; then
         if sudo umount "$mp" 2>/dev/null || sudo fusermount3 -u "$mp" 2>/dev/null; then
           echo "Unmounted $mp — safe to unplug the drive."
         else
           echo "Could not unmount $mp. Close anything using it (e.g. a file manager) and retry." >&2
         fi
       fi
       pause ;;
    5) echo; find "${ARCHIVE_ROOT}/incoming" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
         | sort | while read -r d; do printf '  %s  (%s)\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"; done
       [[ -d "${ARCHIVE_ROOT}/incoming" ]] || echo "  (archive is empty)"
       pause ;;
    6) echo; archive-verify || true; pause ;;
    q|Q) exit 0 ;;
    *) echo "Pick 1-6 or q."; sleep 1 ;;
  esac
done
SCRIPT
sudo chmod +x /usr/local/bin/archive

# ----------------------------------------------------------------------------------------------
# 9. Directories
# ----------------------------------------------------------------------------------------------
step "Writing settings and creating archive directories"
sudo tee "${CONFIG_SYS}" >/dev/null <<EOF
# ${CONFIG_SYS} — settings for the archive ingestion tools.
# Edit and save; safe-mount, ingest-verify, archive-verify, and archive re-read this on each run
# (no reinstall needed). Per-user overrides may go in \${XDG_CONFIG_HOME:-~/.config}/archive-ingest.conf.

# Where verified copies are written. Point this at your archive volume's mountpoint.
ARCHIVE_ROOT="${ARCHIVE_ROOT}"

# Where source media is mounted read-only.
INGEST_MNT="${INGEST_MNT}"

# Refuse to ingest unless ARCHIVE_ROOT is a separate mounted volume (guards against the archive
# silently landing on the OS disk if the drive is not mounted). "false" for a single-disk setup.
REQUIRE_MOUNTED_DEST="${REQUIRE_MOUNTED_DEST}"

# Keep at least this many GiB free on the archive volume after a copy (refuse otherwise).
MIN_FREE_GIB="${MIN_FREE_GIB}"
EOF
info "settings written to ${CONFIG_SYS}"
sudo mkdir -p "${ARCHIVE_ROOT}/incoming" "${ARCHIVE_ROOT}/images" "${INGEST_MNT}"
sudo chown "$(id -un)":"$(id -gn)" "${ARCHIVE_ROOT}" "${ARCHIVE_ROOT}/incoming" "${ARCHIVE_ROOT}/images"

# ----------------------------------------------------------------------------------------------
# 10. Summary
# ----------------------------------------------------------------------------------------------
log "Installed. For most work, just run:   archive"
cat <<EOF
    Guided menu (recommended for day-to-day):   archive

    Expert commands (the menu calls these):
      safe-mount                 # pick a drive, mount it read-only
      safe-mount /dev/sdX1 label # mount a specific partition read-only
      ingest-verify /mnt/ingest/<name> <label>   # verified copy into the archive
      archive-verify             # re-check every copy against its checksums (detect bit-rot)
      archive-verify ${ARCHIVE_ROOT}/incoming/<label>/<timestamp>   # check one copy

    Settings (edit, then re-run any command — no reinstall):
      ${CONFIG_SYS}    # ARCHIVE_ROOT, INGEST_MNT, REQUIRE_MOUNTED_DEST, MIN_FREE_GIB

    Network shares (read-only):
      avahi-browse -alrt                          # find Macs / NAS via mDNS
      smbclient -L //HOST -U user                  # list a Windows/Samba host's shares
      nmap -p139,445 --open 192.168.1.0/24         # find SMB hosts on the LAN
      sudo mount -t cifs //HOST/Share /mnt/ingest/share \\
        -o ro,username=USER,vers=3.0,uid=$(id -u),gid=$(id -g)
      # very old devices may need vers=1.0 (insecure — isolated network only)

    Old/failing drive: image FIRST, then work from the image:
      sudo ddrescue -d -r3 /dev/sdX /srv/archive/images/sdX.img /srv/archive/images/sdX.map
      sudo losetup --read-only -fP /srv/archive/images/sdX.img   # then safe-mount the loop part
      sudo photorec /srv/archive/images/sdX.img                  # recover deleted/lost files

    BitLocker volume, read-only:
      sudo dislocker -r -V /dev/sdX1 -p<recovery-key> -- /mnt/bitlocker
      sudo mount -o ro,loop /mnt/bitlocker/dislocker-file /mnt/ingest/bl
EOF
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  warn "Optional components skipped (not fatal): ${SKIPPED[*]}"
fi
set +x
log "Phase 1 (hardened) complete. Full log: ${LOGFILE}"
