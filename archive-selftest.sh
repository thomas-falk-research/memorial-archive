#!/usr/bin/env bash
#
# archive-selftest.sh — end-to-end self-test of the ingestion pipeline, on SCRATCH storage.
#
# It builds small file-backed loopback "drives" in a temp dir (it NEVER touches /srv/archive or your
# real backup), formats each with a different filesystem, seeds them with deliberately tricky files,
# then drives each through the REAL safe-mount -> ingest-verify -> archive-verify pipeline and ASSERTS
# the safety guarantees — not just the happy path:
#
#   * safe-mount engages a block-layer write-block that actually REJECTS a write, and mounts read-only;
#   * ingest-verify produces the data/ BagIt layout + a matching SHA256SUMS, REFUSES an incomplete copy
#     (the hard completeness gate), and REFUSES a destination that isn't a separate mounted volume;
#   * archive-verify passes a clean copy and FAILS a single tampered byte (bit-rot detection);
#   * the failing-drive workflow (ddrescue an image, then ingest the image) works end to end.
#
# Why: prove the whole chain works on the real filesystem types (NTFS / exFAT / HFS+ / FAT / ext4)
# BEFORE any irreplaceable data is ingested — and re-prove it after updates. APFS and BitLocker can't
# be created on Linux, so they aren't covered here (test those with real media; see the README).
#
# Safety: all state lives under a mktemp scratch dir; it only formats/mounts loop devices it created
# itself; it refuses to aim the scratch archive at /srv; and a trap unmounts + detaches + removes
# everything on any exit. Isolation from your real settings is via a scratch XDG config (the tools
# read the per-user config last, so it overrides /etc/archive-ingest.conf for this run only).
#
# Run as a REGULAR user with sudo (it needs sudo for losetup / mount / blockdev). It installs nothing
# and is intentionally NOT in the manage.sh menu.
#
#   ./archive-selftest.sh [--keep] [--help]
#     --keep   leave the scratch dir in place at the end (for inspection)
#   Env: SELFTEST_FS="ext4 ntfs ..."  limit which filesystems are tested (default: all five).
#
set -uo pipefail
umask 022

KEEP=false
usage() {
  cat <<USAGE
archive-selftest.sh — end-to-end self-test of the ingestion pipeline on scratch loopback storage.
It never touches /srv/archive or your backup. Run as a regular user with sudo.

Usage: ${0##*/} [--keep] [--help]
  --keep   leave the scratch dir in place at the end (for inspection)
Env: SELFTEST_FS="ext4 ntfs exfat vfat hfsplus"   limit which filesystems are tested.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ---- output helpers --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  red=$'\033[1;31m'; grn=$'\033[1;32m'; yel=$'\033[1;33m'; cyn=$'\033[0;36m'; dim=$'\033[2m'; rst=$'\033[0m'
else red=""; grn=""; yel=""; cyn=""; dim=""; rst=""; fi
P=0; F=0; S=0
hdr()  { printf '\n%s━━ %s%s\n' "$cyn" "$*" "$rst"; }
pass() { printf '  %s✓%s %s\n' "$grn" "$rst" "$*"; P=$((P+1)); }
failc(){ printf '  %s✗%s %s\n' "$red" "$rst" "$*" >&2; F=$((F+1)); }
skip() { printf '  %s·%s %s\n' "$dim" "$rst" "$*"; S=$((S+1)); }
note() { printf '    %s%s%s\n' "$dim" "$*" "$rst"; }
die()  { printf '%sFATAL:%s %s\n' "$red" "$rst" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- preflight -------------------------------------------------------------------------------
[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo); it sudo's when needed."
have sudo || die "sudo is required."
for c in safe-mount ingest-verify archive-verify; do
  have "$c" || die "'$c' is not installed — run archive-ingest-setup.sh first (this tests the installed tools)."
done
for t in losetup blockdev mkfs.ext4 findmnt numfmt dd; do
  have "$t" || die "Required tool not found: $t."
done

printf '%s' "$cyn"
printf '╭────────────────────────────────────────────────╮\n'
printf '│  archive-selftest — ingestion pipeline E2E test  │\n'
printf '╰────────────────────────────────────────────────╯%s\n' "$rst"
note "Scratch-only: this never touches /srv/archive or your backup."
sudo -v || die "sudo authentication failed."

# ---- scratch sandbox + guaranteed teardown ---------------------------------------------------
LOOPS=(); MOUNTS=()
WORK="$(mktemp -d "${TMPDIR:-/tmp}/archive-selftest.XXXXXX")" || die "could not create a scratch dir."
case "$WORK" in
  /srv|/srv/*) die "refusing: scratch dir resolved under /srv ($WORK)." ;;
esac

# shellcheck disable=SC2317  # invoked via 'trap', which shellcheck can't see as a call
cleanup() {
  local i l
  for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
    sudo umount "${MOUNTS[i]}" 2>/dev/null || sudo umount -l "${MOUNTS[i]}" 2>/dev/null || true
  done
  for l in "${LOOPS[@]}"; do
    sudo blockdev --setrw "$l" 2>/dev/null || true
    sudo losetup -d "$l" 2>/dev/null || true
  done
  if [[ "$KEEP" == true ]]; then printf '\n%sScratch kept at:%s %s\n' "$yel" "$rst" "$WORK"; return; fi
  rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Make a loop device from a fresh zero image. On success sets global $LOOP and RECORDS it for
# teardown. Sets a global (not echo + $(...)) so the LOOPS array is updated in THIS shell — a
# command-substitution subshell would lose the tracking and leak the loop device.
LOOP=""
new_loop() {  # $1=image-path  $2=size-MiB
  local img="$1" mb="$2"
  LOOP=""
  dd if=/dev/zero of="$img" bs=1M count="$mb" status=none 2>/dev/null || return 1
  LOOP="$(sudo losetup --find --show "$img" 2>/dev/null)" || return 1
  [[ -n "$LOOP" ]] || return 1
  LOOPS+=("$LOOP")
  sudo udevadm settle 2>/dev/null || true   # let the device node settle before mkfs/mount (avoid races)
}
track_mount() { MOUNTS+=("$1"); }

# ---- build the scratch ARCHIVE on its own mounted volume (so REQUIRE_MOUNTED_DEST=true is real) --
hdr "Setting up the scratch archive (isolated loopback volume)"
AROOT="$WORK/archive"; INGEST_MNT="$WORK/ingest"; mkdir -p "$AROOT" "$INGEST_MNT" "$WORK/stage"
new_loop "$WORK/archive.img" 1024 || die "could not create the scratch archive loop."
aloop="$LOOP"
sudo mkfs.ext4 -q -F "$aloop" >/dev/null 2>&1 || die "mkfs.ext4 failed on the scratch archive image."
sudo mount "$aloop" "$AROOT" || die "could not mount the scratch archive volume."
track_mount "$AROOT"
sudo chown "$(id -u):$(id -g)" "$AROOT"   # ingest-verify writes as us, not root
if findmnt -no TARGET -T "$AROOT" | grep -qx "$AROOT"; then
  pass "Scratch archive is a separate mounted volume ($AROOT)."
else
  failc "Scratch archive did not mount as its own volume — REQUIRE_MOUNTED_DEST tests would be moot."
fi

# Isolate the installed tools onto this scratch archive via a per-user (XDG) config, which they source
# AFTER /etc/archive-ingest.conf — so it overrides the real settings for this run only.
export XDG_CONFIG_HOME="$WORK/xdg"; mkdir -p "$XDG_CONFIG_HOME"
cat > "$XDG_CONFIG_HOME/archive-ingest.conf" <<CONF
ARCHIVE_ROOT=$AROOT
INGEST_MNT=$INGEST_MNT
REQUIRE_MOUNTED_DEST=true
MIN_FREE_GIB=0
MAX_ARCHIVE_GIB=100000
CONF
note "Isolation config: $XDG_CONFIG_HOME/archive-ingest.conf (ARCHIVE_ROOT=$AROOT)"

# ---- build the two seed filesets once (copied into each image) --------------------------------
# A 'portable' set every target FS accepts, plus a 'posix' superset with a newline in a filename
# (valid only on ext4/HFS+), which stresses ingest-verify's NUL-safe file counting.
SEED_P="$WORK/seed-portable"; SEED_X="$WORK/seed-posix"
build_seed() {  # $1=dir  $2=with-newline(true/false)
  local d="$1"
  mkdir -p "$d/nested/deep"
  printf 'hello\n'              > "$d/normal.txt"
  printf 'has spaces\n'         > "$d/with spaces.txt"
  printf 'unicode\n'            > "$d/café-ünïcode-名前.txt"
  printf 'decoy manifest\n'     > "$d/SHA256SUMS"        # a SOURCE file named like our metadata
  : > "$d/empty.bin"                                     # zero-byte file
  head -c 1048576 /dev/urandom  > "$d/blob.bin"          # 1 MiB binary
  printf 'leaf\n'              > "$d/nested/deep/leaf.txt"
  [[ "$2" == true ]] && printf 'x' > "$d/$(printf 'two\nlines.txt')"
}
build_seed "$SEED_P" false
build_seed "$SEED_X" true

# Mount a loop read-write, copy a seed fileset in, make it readable by the ingest user, unmount.
# (A real drive's files are readable by the operator; only ext4's root-owned lost+found wouldn't be,
# which is a permissions concern — not what this filesystem-compatibility test is about.)
stage_seed() {  # $1=loop  $2=seed-dir
  sudo mount "$1" "$WORK/stage" 2>/dev/null || return 1
  track_mount "$WORK/stage"
  sudo cp -r "$2/." "$WORK/stage/" 2>/dev/null
  sudo chmod -R a+rX "$WORK/stage" 2>/dev/null
  sudo sync
  sudo umount "$WORK/stage" 2>/dev/null || sudo umount -l "$WORK/stage" 2>/dev/null
}

# ---- per-filesystem pipeline test ------------------------------------------------------------
mkfs_for() {  # $1=fs ; formats $2=loop ; returns nonzero if the mkfs tool is missing
  case "$1" in
    ext4)    have mkfs.ext4    && sudo mkfs.ext4 -q -F "$2" >/dev/null 2>&1 ;;
    ntfs)    have mkfs.ntfs    && sudo mkfs.ntfs -Q -F "$2" >/dev/null 2>&1 ;;
    exfat)   have mkfs.exfat   && sudo mkfs.exfat "$2"      >/dev/null 2>&1 ;;
    vfat)    have mkfs.vfat    && sudo mkfs.vfat "$2"       >/dev/null 2>&1 ;;
    hfsplus) have mkfs.hfsplus && sudo mkfs.hfsplus "$2"    >/dev/null 2>&1 ;;
    *) return 2 ;;
  esac
}
tool_for() { case "$1" in ext4) echo mkfs.ext4;; ntfs) echo mkfs.ntfs;; exfat) echo mkfs.exfat;; vfat) echo mkfs.vfat;; hfsplus) echo mkfs.hfsplus;; esac; }

declare -a GOOD_DIRS=()   # verified copies to re-check / tamper later
test_fs() {
  local fs="$1" label="selftest-$1" img loop seed mnt tsdir
  hdr "Filesystem: $fs"
  if ! have "$(tool_for "$fs")"; then skip "$fs: $(tool_for "$fs") not installed — skipping (install it to include $fs)."; return; fi

  img="$WORK/src-$fs.img"
  if ! new_loop "$img" 64; then failc "$fs: could not create loop device."; return; fi
  loop="$LOOP"
  if ! mkfs_for "$fs" "$loop"; then failc "$fs: mkfs failed."; return; fi

  # Seed the image (newline-in-name file only on the POSIX filesystems that allow it).
  seed="$SEED_P"; [[ "$fs" == ext4 || "$fs" == hfsplus ]] && seed="$SEED_X"
  if ! stage_seed "$loop" "$seed"; then
    failc "$fs: could not mount the image to seed it (kernel module/tool missing here?)."; return
  fi

  # 1) safe-mount: write-block + read-only mount.
  if ! safe-mount "$loop" "$label" </dev/null >/dev/null 2>&1; then
    failc "$fs: safe-mount failed (could not write-block + mount read-only)."; return
  fi
  mnt="$(findmnt -nro TARGET --source "$loop" 2>/dev/null | head -1)"
  if [[ -n "$mnt" ]]; then track_mount "$mnt"; pass "$fs: safe-mount mounted it read-only at $mnt."
  else failc "$fs: safe-mount reported success but no mount found."; return; fi

  # 2) the write-block must actually reject writes (block layer) and the mount must be 'ro'.
  if [[ "$(sudo blockdev --getro "$loop" 2>/dev/null)" == "1" ]]; then pass "$fs: block-layer write-block engaged (getro=1)."
  else failc "$fs: device is NOT write-blocked (getro != 1)."; fi
  if sudo dd if=/dev/zero of="$loop" bs=4096 count=1 conv=notrunc </dev/null >/dev/null 2>&1; then
    failc "$fs: a raw write to the write-blocked device SUCCEEDED — that must never happen."
  else pass "$fs: a raw write to the device was correctly rejected."; fi
  case ",$(findmnt -nro OPTIONS --source "$loop" 2>/dev/null)," in *,ro,*) pass "$fs: mount options include 'ro'.";; *) failc "$fs: mount is not read-only.";; esac

  # 3) ingest-verify: verified copy with the data/ layout + matching manifest.
  if ingest-verify "$mnt" "$label" </dev/null >/dev/null 2>&1; then
    tsdir="$(find "$AROOT/incoming/$label" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
    if [[ -n "$tsdir" && -d "$tsdir/data" && -f "$tsdir/SHA256SUMS" && -f "$tsdir/PROVENANCE.txt" && ! -f "$tsdir/.INCOMPLETE" ]]; then
      local src_n cp_n; src_n="$(find "$mnt" -type f -printf 'x' 2>/dev/null | wc -c)"; cp_n="$(wc -l < "$tsdir/SHA256SUMS")"
      if [[ "$src_n" == "$cp_n" ]]; then pass "$fs: ingest-verify OK — data/ layout, manifest, provenance ($cp_n files, all hashed)."; GOOD_DIRS+=("$tsdir")
      else failc "$fs: ingest copied $cp_n files but source had $src_n."; fi
    else failc "$fs: ingest-verify exited 0 but the expected artifacts are missing/incomplete."; fi
  else failc "$fs: ingest-verify FAILED on a healthy source."; fi
}

read -ra FSLIST <<< "${SELFTEST_FS:-ext4 ntfs exfat vfat hfsplus}"
for fs in "${FSLIST[@]}"; do test_fs "$fs"; done

# ---- whole-archive scrub (the no-arg 'scan everything' path) ----------------------------------
hdr "archive-verify: full scrub of every copy"
if (( ${#GOOD_DIRS[@]} == 0 )); then
  skip "No verified copies were produced — nothing to scrub (see failures above)."
elif archive-verify </dev/null >/dev/null 2>&1; then
  pass "archive-verify (no args) re-checked all ${#GOOD_DIRS[@]} copy(ies): all match their manifests."
else
  failc "archive-verify reported a mismatch on freshly-made copies — unexpected."
fi

# ---- bit-rot detection: a single tampered byte must FAIL ---------------------------------------
hdr "Bit-rot detection (tamper one byte, expect a FAIL)"
if (( ${#GOOD_DIRS[@]} == 0 )); then
  skip "No copy available to tamper."
else
  tdir="${GOOD_DIRS[0]}"; victim="$(find "$tdir/data" -type f ! -name empty.bin 2>/dev/null | head -1)"
  if [[ -n "$victim" ]]; then
    printf 'ROT' >> "$victim"   # change the content so its hash no longer matches the manifest
    if archive-verify "$tdir" </dev/null >/dev/null 2>&1; then
      failc "archive-verify PASSED a copy with a tampered file — bit-rot would go undetected."
    else
      pass "archive-verify caught the tampered file (exited non-zero)."
    fi
  else skip "Could not pick a file to tamper."; fi
fi

# ---- completeness gate: a partial copy must be REFUSED and left .INCOMPLETE --------------------
hdr "Completeness gate (rsync drops a file, expect REFUSED + .INCOMPLETE)"
gimg="$WORK/src-gate.img"; gloop=""; new_loop "$gimg" 64 && gloop="$LOOP"
if [[ -n "$gloop" ]] && sudo mkfs.ext4 -q -F "$gloop" >/dev/null 2>&1 && stage_seed "$gloop" "$SEED_P"; then
  if safe-mount "$gloop" "selftest-gate" </dev/null >/dev/null 2>&1; then
    gmnt="$(findmnt -nro TARGET --source "$gloop" | head -1)"; [[ -n "$gmnt" ]] && track_mount "$gmnt"
    # rsync shim: copy everything for real, then delete one file and exit 0, so the copied count is
    # short of the source count — exactly what the hard completeness gate must catch.
    mkdir -p "$WORK/shim"
    cat > "$WORK/shim/rsync" <<'SHIM'
#!/usr/bin/env bash
"${REAL_RSYNC:-/usr/bin/rsync}" "$@"; rc=$?
dst="${@: -1}"; v="$(find "$dst" -type f 2>/dev/null | head -1)"
[[ -n "$v" ]] && rm -f "$v"
exit 0
SHIM
    chmod +x "$WORK/shim/rsync"
    if REAL_RSYNC="$(command -v rsync)" PATH="$WORK/shim:$PATH" ingest-verify "$gmnt" "selftest-gate" </dev/null >/dev/null 2>&1; then
      failc "ingest-verify ACCEPTED an incomplete copy — the completeness gate did not trip."
    else
      if find "$AROOT/incoming/selftest-gate" -name .INCOMPLETE 2>/dev/null | grep -q .; then
        pass "ingest-verify refused the short copy and left it marked .INCOMPLETE."
      else
        failc "ingest-verify exited non-zero but did not leave a .INCOMPLETE marker."
      fi
    fi
  else failc "completeness gate: safe-mount of the gate image failed."; fi
else
  skip "Completeness gate: could not stage the gate image here."
fi

# ---- mounted-destination guard: ingest into a non-mounted archive must be REFUSED --------------
hdr "Mounted-destination guard (REQUIRE_MOUNTED_DEST=true)"
badxdg="$WORK/xdg-bad"; mkdir -p "$badxdg" "$WORK/not-a-mount"
cat > "$badxdg/archive-ingest.conf" <<CONF
ARCHIVE_ROOT=$WORK/not-a-mount
INGEST_MNT=$INGEST_MNT
REQUIRE_MOUNTED_DEST=true
MIN_FREE_GIB=0
CONF
if XDG_CONFIG_HOME="$badxdg" ingest-verify "$SEED_P" "selftest-guard" </dev/null >/dev/null 2>&1; then
  failc "ingest-verify wrote to an archive that is NOT a separate mount — the guard failed."
else
  pass "ingest-verify refused a destination that isn't a separate mounted volume."
fi

# ---- failing-drive workflow: ddrescue an image, then ingest the image --------------------------
hdr "Failing-drive workflow (ddrescue image -> ingest the image)"
if ! have ddrescue; then
  skip "ddrescue not installed (gddrescue) — skipping the image-then-ingest workflow."
else
  rimg="$WORK/src-rescue.img"; rloop=""; new_loop "$rimg" 64 && rloop="$LOOP"
  if [[ -n "$rloop" ]] && sudo mkfs.ext4 -q -F "$rloop" >/dev/null 2>&1 && stage_seed "$rloop" "$SEED_P"; then
    # Image the (here, healthy) "drive" with ddrescue, then mount the IMAGE via a loop and ingest it —
    # the documented path for an old/failing disk that must not be mounted directly.
    iloop=""
    if sudo ddrescue -d "$rloop" "$WORK/rescue.dd" "$WORK/rescue.map" >/dev/null 2>&1; then
      # Attach the rescued IMAGE itself as a loop and ingest from it (never mount a failing disk).
      iloop="$(sudo losetup --find --show "$WORK/rescue.dd" 2>/dev/null)" && LOOPS+=("$iloop")
    fi
    if [[ -n "${iloop:-}" ]] && safe-mount "$iloop" "selftest-rescue" </dev/null >/dev/null 2>&1; then
      imnt="$(findmnt -nro TARGET --source "$iloop" | head -1)"; [[ -n "$imnt" ]] && track_mount "$imnt"
      if ingest-verify "$imnt" "selftest-rescue" </dev/null >/dev/null 2>&1 \
         && ! find "$AROOT/incoming/selftest-rescue" -name .INCOMPLETE | grep -q .; then
        pass "ddrescue image -> safe-mount -> ingest-verify completed and verified."
      else
        failc "ingesting the ddrescue image did not produce a verified copy."
      fi
    else
      failc "could not safe-mount the ddrescue image."
    fi
  else
    skip "Failing-drive workflow: could not stage the source image here."
  fi
fi

# ---- summary ---------------------------------------------------------------------------------
printf '\n%s────────── summary ──────────%s\n' "$cyn" "$rst"
printf '  %s%d passed%s   %s%d failed%s   %s%d skipped%s\n' "$grn" "$P" "$rst" "$red" "$F" "$rst" "$dim" "$S" "$rst"
if (( F > 0 )); then
  printf '  %sSome checks FAILED — see the ✗ lines above.%s\n' "$red" "$rst"; exit 1
else
  printf '  %sIngestion pipeline passed end-to-end on the tested filesystems.%s\n' "$grn" "$rst"
  (( S > 0 )) && printf '  %s(%d skipped — usually a missing mkfs tool or filesystem support.)%s\n' "$dim" "$S" "$rst"
  exit 0
fi
