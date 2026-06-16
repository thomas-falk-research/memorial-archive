#!/usr/bin/env bash
#
# make-ubuntu-usb.sh
#
# Create a bootable USB drive for the latest stable Ubuntu Desktop (amd64 / x86-64),
# run from a Raspberry Pi (or any Debian-based Linux). The Pi only writes the image;
# it never boots it, so building an x86-64 stick from an ARM host is expected to work.
#
# What it does, in order:
#   1. Re-runs itself under sudo (device writes need root).
#   2. Checks/installs required tools.
#   3. Auto-detects the latest *stable* Ubuntu Desktop release on releases.ubuntu.com
#      (skips beta/rc directories). Override with UBUNTU_RELEASE=26.04 if you want.
#   4. Downloads SHA256SUMS + SHA256SUMS.gpg, GPG-verifies the checksum file against
#      Ubuntu's pinned CD-image signing keys, then downloads the ISO (with resume +
#      on-disk cache) and checks its SHA256 against the *verified* checksum.
#   5. Lists only removable/USB disks, never the disk the system is running from.
#      You pick one and re-type its name to confirm before anything is erased.
#   6. Unmounts it, writes the ISO with dd, flushes, then (by default) reads the data
#      back and compares hashes to prove the write is byte-for-byte correct.
#
# Configuration (all optional, via environment variables):
#   UBUNTU_RELEASE        Pin a release, e.g. "26.04" or "24.04.4". Default: auto-detect.
#   TARGET_DEVICE         Pre-select a disk, e.g. "/dev/sda". Still requires confirmation.
#   VERIFY_WRITE=0        Skip the post-write read-back verification (faster). Default: 1.
#   SKIP_GPG=1            Skip GPG verification (SHA256-only). Discouraged. Default: 0.
#   KEYSERVER             GPG keyserver. Default: hkps://keyserver.ubuntu.com
#   UBUNTU_RELEASES_BASE  Mirror base URL. Default: https://releases.ubuntu.com
#
# SAFETY: writing to the wrong disk destroys data irreversibly. This script will not
# offer the running system's disk and requires you to type the target name to proceed,
# but you are still responsible for confirming you picked the right device.

set -Eeuo pipefail

# ----- Re-run as root, preserving configuration across sudo's env reset --------------
if [[ ${EUID} -ne 0 ]]; then
    exec sudo \
        UBUNTU_RELEASE="${UBUNTU_RELEASE:-}" \
        UBUNTU_RELEASES_BASE="${UBUNTU_RELEASES_BASE:-}" \
        VERIFY_WRITE="${VERIFY_WRITE:-}" \
        SKIP_GPG="${SKIP_GPG:-}" \
        KEYSERVER="${KEYSERVER:-}" \
        TARGET_DEVICE="${TARGET_DEVICE:-}" \
        -- "${BASH_SOURCE[0]}" "$@"
fi

export LC_ALL=C   # deterministic tool output for parsing

# ----- Configuration ------------------------------------------------------------------
RELEASES_BASE="${UBUNTU_RELEASES_BASE:-https://releases.ubuntu.com}"
RELEASES_BASE="${RELEASES_BASE%/}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-}"
TARGET_DEVICE="${TARGET_DEVICE:-}"
VERIFY_WRITE="${VERIFY_WRITE:-1}"
SKIP_GPG="${SKIP_GPG:-0}"
KEYSERVER="${KEYSERVER:-hkps://keyserver.ubuntu.com}"

# Ubuntu CD Image signing keys. Full fingerprints are pinned and re-checked after import,
# so a malicious keyserver substituting a key (short-ID collision) is detected.
# Sources: Ubuntu security docs (image verification) and ubuntu.com "how to verify".
UBUNTU_KEY_IDS=("0x46181433FBB75451" "0xD94AA3F0EFE21092")
UBUNTU_KEY_FPRS=(
    "843938DF228D22F7B3742BC0D94AA3F0EFE21092"   # Ubuntu CD Image Automatic Signing Key (2012) -- signs current releases
    "C5986B4F1257FFA86632CBA746181433FBB75451"   # Ubuntu CD Image Automatic Signing Key (legacy)
)

# Cache the ISO in the invoking user's home so re-runs do not re-download ~6 GB.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
fi
REAL_HOME="${REAL_HOME:-${HOME:-/root}}"
CACHE_DIR="${REAL_HOME}/.cache/ubuntu-usb"

# ----- Logging helpers ----------------------------------------------------------------
if [[ -t 2 ]]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_BLU=$'\033[36m'; C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_RST=""
fi
info() { printf '%s[*]%s %s\n' "${C_BLU}" "${C_RST}" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[x] %s%s\n' "${C_RED}" "$*" "${C_RST}" >&2; exit 1; }

hsize() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

ask() { # prompt -> echoes the user's line (reads the controlling terminal)
    local prompt="$1" reply=""
    printf '%s' "${prompt}" >&2
    IFS= read -r reply < /dev/tty || die "No input (need an interactive terminal). Aborted."
    printf '%s' "${reply}"
}

# Extract one KEY="value" field from a line of `lsblk -P` output.
get_field() {
    local key="$1" line="$2"
    if [[ "${line}" =~ (^|[[:space:]])${key}=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
    return 0
}

# ----- Cleanup ------------------------------------------------------------------------
WORK="$(mktemp -d)"
cleanup() { [[ -n "${WORK:-}" && -d "${WORK}" ]] && rm -rf "${WORK}"; }
trap cleanup EXIT
trap 'die "Interrupted."' INT TERM

export GNUPGHOME="${WORK}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

# ----- Dependencies -------------------------------------------------------------------
declare -A CMD_PKG=(
    [curl]=curl [gpg]=gnupg [lsblk]=util-linux [findmnt]=util-linux
    [umount]=util-linux [blockdev]=util-linux [partprobe]=parted
    [sha256sum]=coreutils [numfmt]=coreutils [stat]=coreutils [dd]=coreutils
)
ensure_deps() {
    local cmd missing=()
    for cmd in curl gpg lsblk findmnt umount blockdev sha256sum numfmt stat dd; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${CMD_PKG[$cmd]}")
    done
    # partprobe is a nice-to-have (refreshing the kernel partition table); not fatal.
    command -v partprobe >/dev/null 2>&1 || true
    ((${#missing[@]})) || return 0
    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
    warn "Missing required packages: ${missing[*]}"
    local a; a="$(ask "Install them now with apt-get? [y/N] ")"
    [[ "${a,,}" == "y" || "${a,,}" == "yes" ]] || die "Cannot continue without: ${missing[*]}"
    apt-get update -qq || die "apt-get update failed."
    apt-get install -y "${missing[@]}" || die "Failed to install: ${missing[*]}"
}

# ----- Networking helper --------------------------------------------------------------
fetch() { curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused "$1"; }

# ----- Resolve which release + ISO to use --------------------------------------------
REL=""; ISO_NAME=""
resolve_release() {
    local listing versions=() v sums iso
    if [[ -n "${UBUNTU_RELEASE}" ]]; then
        REL="${UBUNTU_RELEASE}"
    else
        info "Detecting latest stable Ubuntu Desktop release..."
        listing="$(fetch "${RELEASES_BASE}/")" \
            || die "Cannot reach ${RELEASES_BASE} (check the Pi's internet connection)."
        # Numeric release directories only (skip codename symlinks), highest first.
        mapfile -t versions < <(
            grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' <<<"${listing}" \
            | sed -E 's#href="([^"]+)/"#\1#' | sort -Vr | uniq
        )
        ((${#versions[@]})) || die "No release directories found at ${RELEASES_BASE}."
        # First directory that actually contains a FINAL desktop amd64 ISO wins.
        # Beta/rc images are named ubuntu-<v>-beta-desktop-amd64.iso, so the regex below
        # (which requires "-desktop-" immediately after the version) skips them.
        for v in "${versions[@]}"; do
            sums="$(fetch "${RELEASES_BASE}/${v}/SHA256SUMS" 2>/dev/null)" || continue
            iso="$(grep -oE 'ubuntu-[0-9][0-9.]*-desktop-amd64\.iso' <<<"${sums}" | sort -V | tail -1 || true)"
            if [[ -n "${iso}" ]]; then REL="${v}"; ISO_NAME="${iso}"; break; fi
        done
        [[ -n "${REL}" ]] || die "Could not locate a stable desktop amd64 image."
    fi
    if [[ -z "${ISO_NAME}" ]]; then
        sums="$(fetch "${RELEASES_BASE}/${REL}/SHA256SUMS")" \
            || die "Cannot fetch SHA256SUMS for release ${REL}."
        ISO_NAME="$(grep -oE 'ubuntu-[0-9][0-9.]*-desktop-amd64\.iso' <<<"${sums}" | sort -V | tail -1 || true)"
        [[ -n "${ISO_NAME}" ]] || die "No desktop amd64 image found in release ${REL}."
    fi
    ISO_URL="${RELEASES_BASE}/${REL}/${ISO_NAME}"
    SUMS_URL="${RELEASES_BASE}/${REL}/SHA256SUMS"
    SIG_URL="${RELEASES_BASE}/${REL}/SHA256SUMS.gpg"
}

# ----- Verify the checksum file's signature, then read our ISO's expected hash --------
ISO_SHA256=""
verify_sums_and_get_hash() {
    info "Downloading checksums for ${REL}..."
    curl -fsSL -o "${WORK}/SHA256SUMS"     "${SUMS_URL}" || die "Failed to download SHA256SUMS."
    curl -fsSL -o "${WORK}/SHA256SUMS.gpg" "${SIG_URL}"  || die "Failed to download SHA256SUMS.gpg."

    if [[ "${SKIP_GPG}" == "1" ]]; then
        warn "SKIP_GPG=1: skipping signature check. Integrity is checked via SHA256 only,"
        warn "which detects corruption but NOT a maliciously substituted image. Not recommended."
    else
        info "Importing and verifying Ubuntu signing keys..."
        if ! gpg --batch --quiet --keyserver "${KEYSERVER}" \
                 --recv-keys "${UBUNTU_KEY_IDS[@]}" >/dev/null 2>&1; then
            die "Could not fetch signing keys from ${KEYSERVER}. If this network blocks keyservers,
     either fix connectivity or re-run with SKIP_GPG=1 (accepts SHA256-only integrity)."
        fi
        local fpr
        for fpr in "${UBUNTU_KEY_FPRS[@]}"; do
            gpg --batch --quiet --fingerprint "${fpr}" >/dev/null 2>&1 \
                || die "Pinned signing key ${fpr} not present after import (possible tampering). Aborting."
        done
        if ! gpg --batch --quiet --verify "${WORK}/SHA256SUMS.gpg" "${WORK}/SHA256SUMS" >/dev/null 2>&1; then
            die "GPG signature on SHA256SUMS is INVALID. Do not use these files."
        fi
        ok "Checksum file signature verified against Ubuntu's CD-image key."
    fi

    # Pull the expected hash for exactly our ISO (strip an optional leading '*').
    ISO_SHA256="$(awk -v f="${ISO_NAME}" '{n=$2; sub(/^\*/,"",n); if (n==f) print $1}' \
                  "${WORK}/SHA256SUMS" | head -1)"
    [[ "${ISO_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] \
        || die "Could not find a valid SHA256 for ${ISO_NAME} in SHA256SUMS."
}

# ----- Download (cache-aware, resumable) + verify the ISO -----------------------------
ISO_PATH=""
check_iso_hash() {
    [[ -f "$1" ]] || return 1
    local got; got="$(sha256sum "$1" | awk '{print $1}')"
    [[ "${got}" == "${ISO_SHA256}" ]]
}
obtain_iso() {
    mkdir -p "${CACHE_DIR}"
    ISO_PATH="${CACHE_DIR}/${ISO_NAME}"

    if check_iso_hash "${ISO_PATH}"; then
        ok "Using cached, verified ISO: ${ISO_PATH}"
        return 0
    fi

    # Optional pre-flight: warn early if the cache filesystem can't hold the ISO.
    local len avail
    len="$(curl -fsIL "${ISO_URL}" 2>/dev/null | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v}')" || true
    if [[ "${len}" =~ ^[0-9]+$ ]]; then
        avail="$(df -P -B1 "${CACHE_DIR}" | awk 'NR==2{print $4}')"
        if [[ "${avail}" =~ ^[0-9]+$ ]] && (( avail < len )); then
            die "Not enough free space in ${CACHE_DIR}: need $(hsize "${len}"), have $(hsize "${avail}")."
        fi
        info "ISO size is $(hsize "${len}")."
    fi

    local opts=(-fL --retry 5 --retry-delay 3 --retry-connrefused)
    if [[ -f "${ISO_PATH}" ]]; then
        info "Resuming previous download..."
        curl "${opts[@]}" -C - -o "${ISO_PATH}" "${ISO_URL}" || warn "Resume failed; retrying from scratch."
        if check_iso_hash "${ISO_PATH}"; then ok "ISO verified."; chown_cache; return 0; fi
    fi
    info "Downloading ${ISO_NAME} ..."
    rm -f "${ISO_PATH}"
    curl "${opts[@]}" -o "${ISO_PATH}" "${ISO_URL}" || die "ISO download failed."
    if check_iso_hash "${ISO_PATH}"; then ok "ISO verified."; chown_cache; return 0; fi
    die "Downloaded ISO failed checksum verification. The download may be corrupt; re-run to retry."
}
chown_cache() {
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
        && chown -R "${SUDO_USER}:${SUDO_USER}" "${CACHE_DIR}" 2>/dev/null || true
}

# ----- Identify the running system's disk(s) so we never offer them -------------------
whole_disk_of() { # partition/dm path -> backing whole-disk path
    local cur="$1" type pk
    while :; do
        type="$(lsblk -dno TYPE "${cur}" 2>/dev/null | head -1)" || return 1
        if [[ "${type}" == "disk" || "${type}" == "loop" ]]; then
            lsblk -dno PATH "${cur}" 2>/dev/null | head -1
            return 0
        fi
        pk="$(lsblk -no PKNAME "${cur}" 2>/dev/null | awk 'NF{print;exit}')" || return 1
        [[ -n "${pk}" ]] || return 1
        cur="/dev/${pk}"
    done
}
declare -A PROTECTED=()
find_protected_disks() {
    local mp src d
    for mp in / /boot /boot/firmware /boot/efi /usr; do
        src="$(findmnt -no SOURCE --target "${mp}" 2>/dev/null)" || continue
        [[ -n "${src}" ]] || continue
        d="$(whole_disk_of "${src}" 2>/dev/null)" || continue
        [[ -n "${d}" ]] && PROTECTED["${d}"]=1
    done
}

# ----- Choose the target disk ---------------------------------------------------------
DEV=""
choose_target() {
    local candidates=() line name type rm hot tran
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        name="$(get_field NAME "${line}")"
        type="$(get_field TYPE "${line}")"
        rm="$(get_field RM "${line}")"
        hot="$(get_field HOTPLUG "${line}")"
        tran="$(get_field TRAN "${line}")"
        [[ "${type}" == "disk" ]] || continue
        [[ -n "${PROTECTED[${name}]:-}" ]] && continue
        if [[ "${tran}" == "usb" || "${rm}" == "1" || "${hot}" == "1" ]]; then
            candidates+=("${line}")
        fi
    done < <(lsblk -dpno NAME,TYPE,RM,HOTPLUG,TRAN,SIZE,VENDOR,MODEL,SERIAL -P)

    ((${#candidates[@]})) \
        || die "No removable/USB disks found (the system disk is never listed). Plug in the USB drive and re-run."

    # Honour TARGET_DEVICE if it matches a candidate.
    if [[ -n "${TARGET_DEVICE}" ]]; then
        for line in "${candidates[@]}"; do
            [[ "$(get_field NAME "${line}")" == "${TARGET_DEVICE}" ]] && { DEV="${TARGET_DEVICE}"; break; }
        done
        [[ -n "${DEV}" ]] || die "${TARGET_DEVICE} is not among the detected removable/USB disks."
    fi

    if [[ -z "${DEV}" ]]; then
        printf '\nRemovable / USB disks (system disk excluded):\n' >&2
        local i=0 v m s sz
        for line in "${candidates[@]}"; do
            i=$((i+1))
            name="$(get_field NAME "${line}")"; sz="$(get_field SIZE "${line}")"
            v="$(get_field VENDOR "${line}")"; m="$(get_field MODEL "${line}")"; s="$(get_field SERIAL "${line}")"
            printf '   [%d] %-12s %-8s %s %s  (serial: %s)\n' \
                "${i}" "${name}" "${sz}" "${v## }" "${m:-unknown}" "${s:-n/a}" >&2
        done
        if ((${#candidates[@]} == 1)); then
            DEV="$(get_field NAME "${candidates[0]}")"
            info "One candidate detected: ${DEV}"
        else
            local n; n="$(ask "Select the disk to ERASE [1-${#candidates[@]}]: ")"
            if ! { [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#candidates[@]} )); }; then
                die "Invalid selection. Aborted (nothing written)."
            fi
            DEV="$(get_field NAME "${candidates[$((n-1))]}")"
        fi
    fi
}

# ----- Confirm, unmount, write, verify ------------------------------------------------
confirm_and_write() {
    printf '\n' >&2
    warn "Target: ${DEV} — current contents:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "${DEV}" >&2 || lsblk "${DEV}" >&2 || true
    printf '\n' >&2
    warn "EVERYTHING on ${DEV} will be permanently destroyed. This cannot be undone."

    local base typed
    base="$(basename "${DEV}")"
    typed="$(ask "Type '${base}' to confirm and proceed: ")"
    [[ "${typed}" == "${base}" ]] || die "Confirmation did not match. Aborted (nothing written)."

    # Size sanity check.
    local dev_bytes iso_bytes
    dev_bytes="$(blockdev --getsize64 "${DEV}")"
    iso_bytes="$(stat -c %s "${ISO_PATH}")"
    (( dev_bytes >= iso_bytes )) \
        || die "${DEV} ($(hsize "${dev_bytes}")) is smaller than the ISO ($(hsize "${iso_bytes}")). Use a larger drive."

    # Unmount any mounted partitions on the target.
    local part
    while IFS= read -r part; do
        [[ -n "${part}" ]] || continue
        if findmnt -rno TARGET "${part}" >/dev/null 2>&1; then
            info "Unmounting ${part}"
            umount "${part}" || die "Could not unmount ${part} (in use). Close anything using it and retry."
        fi
    done < <(lsblk -lnpo NAME "${DEV}")
    udevadm settle 2>/dev/null || true

    info "Writing ${ISO_NAME} to ${DEV} (several minutes; progress below)..."
    dd if="${ISO_PATH}" of="${DEV}" bs=4M status=progress conv=fdatasync
    info "Flushing kernel buffers..."
    sync
    partprobe "${DEV}" 2>/dev/null || blockdev --rereadpt "${DEV}" 2>/dev/null || true

    if [[ "${VERIFY_WRITE}" == "1" ]]; then
        info "Verifying write: reading back $(hsize "${iso_bytes}") and comparing hashes..."
        local back
        back="$(head -c "${iso_bytes}" "${DEV}" | sha256sum | awk '{print $1}')"
        [[ "${back}" == "${ISO_SHA256}" ]] \
            || die "WRITE VERIFICATION FAILED: the drive does not match the ISO. It may be faulty — do not use it."
        ok "Write verified: ${DEV} matches the ISO byte-for-byte."
    else
        warn "VERIFY_WRITE=0: skipped read-back verification."
    fi
    sync
}

# ----- Main ---------------------------------------------------------------------------
main() {
    ensure_deps
    resolve_release
    ok "Selected: Ubuntu ${REL} — ${ISO_NAME}"
    verify_sums_and_get_hash
    obtain_iso
    find_protected_disks
    choose_target
    confirm_and_write
    printf '\n' >&2
    ok "Done. ${DEV} is now a bootable Ubuntu ${REL} installer."
    info "Eject safely:  sync && sudo eject ${DEV}"
    info "Then boot the target PC from it (boot menu is usually F12 / F9 / Esc),"
    info "and choose 'Full installation' in the installer if you want the complete app set."
}
main "$@"
