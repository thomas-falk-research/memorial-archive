#!/usr/bin/env bash
#
# archive-serve-setup.sh — Phase 3: let the family browse the archive from iPhones/iPads.
#
# Publishes the archive as a READ-ONLY SMB share that is reachable ONLY over the Tailscale
# tailnet (and loopback) — never the local network or the internet. iOS/iPadOS's built-in
# Files app speaks SMB natively: Browse -> Connect to Server -> smb://<tailscale-name>.
#
# Safety choices:
#   * read only = yes            (the family can view/copy, never modify or delete)
#   * interfaces = lo tailscale0 + bind interfaces only = yes  (not exposed on LAN/Wi-Fi/WAN)
#   * authenticated (no guest)   (a dedicated, login-less SMB account)
#   * SMB2+ only, encryption desired
#
# Reads ARCHIVE_ROOT from /etc/archive-ingest.conf. Run as a REGULAR user with sudo.
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment if desired) -------------------------------------
SAMBA_USER="${SAMBA_USER:-family}"        # the SMB login the family types on their iPhone/iPad
SHARE_NAME="${SHARE_NAME:-archive}"       # the share name shown to clients
MANAGED="/etc/samba/archive-share.conf"   # our managed include (kept separate from smb.conf)

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip prompts; generate a random SMB password and print it
  --help, -h  show this help and exit
Environment overrides: SAMBA_USER (default 'family'), SHARE_NAME (default 'archive'),
SERVE_PATH (default \$ARCHIVE_ROOT/incoming).
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
export DEBIAN_FRONTEND=noninteractive

# Resolve ARCHIVE_ROOT and the path to serve.
ARCHIVE_ROOT="/srv/archive"
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
SERVE_PATH="${SERVE_PATH:-${ARCHIVE_ROOT}/incoming}"
[[ -d "$SERVE_PATH" ]] || die "Path to serve does not exist: $SERVE_PATH
Run archive-ingest-setup.sh and ingest at least one source first, or set SERVE_PATH."

# Serve files as their owner (the archive is owned by whoever ran the ingest installer), so the
# read-only login can actually read them regardless of its own uid.
SERVE_OWNER="$(stat -c %U "$SERVE_PATH" 2>/dev/null || echo root)"
SERVE_GROUP="$(stat -c %G "$SERVE_PATH" 2>/dev/null || echo root)"

log "This will configure a READ-ONLY, tailnet-only SMB share, using sudo:"
printf '    - install: samba\n'
printf '    - share   [%s]  ->  %s   (read only, owner %s:%s)\n' "$SHARE_NAME" "$SERVE_PATH" "$SERVE_OWNER" "$SERVE_GROUP"
printf '    - listen on: lo + tailscale0 ONLY (bind interfaces only) — not the LAN or internet\n'
printf '    - SMB login: %s  (no shell; you set its password below)\n' "$SAMBA_USER"
printf '    - managed config: %s  (included from /etc/samba/smb.conf)\n' "$MANAGED"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi
sudo -v

log "Installing Samba"
sudo apt-get update -y
sudo apt-get install -y samba

# Warn (don't fail) if the tailnet interface isn't up yet — smbd will bind it once it appears.
if ! ip link show tailscale0 >/dev/null 2>&1; then
  warn "tailscale0 not present yet. Run 'sudo tailscale up' first, then 'sudo systemctl restart smbd'."
fi

log "Writing the managed share config"
sudo tee "$MANAGED" >/dev/null <<EOF
# Managed by archive-serve-setup.sh — edit SERVE_PATH/SAMBA_USER and re-run, or edit here and
# 'sudo systemctl restart smbd'. Serves the archive READ-ONLY over the tailnet only.
[global]
   server string = Digital Archive (read-only)
   # Listen ONLY on loopback and the Tailscale interface. Never the LAN/Wi-Fi/WAN.
   interfaces = lo tailscale0
   bind interfaces only = yes
   server min protocol = SMB2
   smb encrypt = desired
   # Friendlier browsing for Apple (iPhone/iPad/Mac) clients.
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:encoding = native
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

[${SHARE_NAME}]
   comment = Digital Archive (read-only)
   path = ${SERVE_PATH}
   browseable = yes
   read only = yes
   guest ok = no
   valid users = ${SAMBA_USER}
   force user = ${SERVE_OWNER}
   force group = ${SERVE_GROUP}
   create mask = 0444
   directory mask = 0555
   veto files = /.INCOMPLETE/
EOF

# Idempotently include our managed file from the main smb.conf (back it up once).
if [[ ! -f /etc/samba/smb.conf.orig ]]; then
  sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.orig 2>/dev/null || true
fi
if ! grep -qF "include = ${MANAGED}" /etc/samba/smb.conf 2>/dev/null; then
  printf '\n# Added by archive-serve-setup.sh\ninclude = %s\n' "$MANAGED" | sudo tee -a /etc/samba/smb.conf >/dev/null
fi

log "Validating the Samba configuration (testparm)"
if ! sudo testparm -s >/dev/null 2>&1; then
  sudo testparm -s 2>&1 | tail -n 20 >&2 || true
  die "Samba config is invalid — NOT restarting the service. Review ${MANAGED}."
fi
info "Configuration is valid."

# ---- Create the read-only SMB account --------------------------------------------------------
log "Setting up the SMB login '${SAMBA_USER}'"
if ! id "$SAMBA_USER" >/dev/null 2>&1; then
  sudo useradd -M -s /usr/sbin/nologin -c "Digital archive (read-only SMB)" "$SAMBA_USER"
  info "created login-less system user '${SAMBA_USER}'"
fi
GENERATED_PW=""
if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$SAMBA_USER"; then
  info "Samba account '${SAMBA_USER}' already exists — leaving its password unchanged."
  info "To reset it later:  sudo smbpasswd ${SAMBA_USER}"
else
  if [[ "${ASSUME_YES}" == "true" ]]; then
    GENERATED_PW="$(openssl rand -base64 12 2>/dev/null || head -c 9 /dev/urandom | base64)"
    pw="$GENERATED_PW"
  else
    read -rsp "Set a password for the '${SAMBA_USER}' SMB login (the family types this on their iPhone): " pw; echo
    read -rsp "Confirm: " pw2; echo
    [[ -n "$pw" ]]      || die "Password cannot be empty."
    [[ "$pw" == "$pw2" ]] || die "Passwords did not match."
  fi
  printf '%s\n%s\n' "$pw" "$pw" | sudo smbpasswd -a -s "$SAMBA_USER" >/dev/null
  sudo smbpasswd -e "$SAMBA_USER" >/dev/null 2>&1 || true
  unset pw pw2
fi

log "Enabling and (re)starting smbd"
sudo systemctl enable --now smbd >/dev/null 2>&1 || true
sudo systemctl restart smbd

# ---- Connection instructions -----------------------------------------------------------------
ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
ts_name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
log "Done — the archive is shared READ-ONLY over your tailnet."
cat <<EOF
    On each iPhone/iPad (must be signed in to the same Tailscale account):
      1. Open the Files app -> Browse.
      2. Tap the "..." menu (top-right) -> Connect to Server.
      3. Enter:   smb://${ts_name:-${ts_ip:-<this-machine-tailscale-name>}}
      4. Connect As: Registered User
         Name:     ${SAMBA_USER}
         Password: $( [[ -n "$GENERATED_PW" ]] && echo "${GENERATED_PW}   (save this now)" || echo "the password you just set" )
      5. Open the "${SHARE_NAME}" share.

    Notes:
      - The share is READ-ONLY: the family can view and copy, never change or delete.
      - It is reachable only over Tailscale (lo + tailscale0), not the local network.
      - If you see no server, run 'sudo tailscale up' on this machine, then
        'sudo systemctl restart smbd', and make sure the iPhone's Tailscale is on.
      - Re-run archive-index after new ingests so search stays current (see archive-search-setup.sh).
EOF
[[ -n "$GENERATED_PW" ]] && warn "The generated password above is shown only once. Save it now."
