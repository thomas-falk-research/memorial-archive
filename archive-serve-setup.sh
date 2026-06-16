#!/usr/bin/env bash
#
# archive-serve-setup.sh — Phase 3: let the family browse the archive from iPhones/iPads.
#
# Publishes the archive as a READ-ONLY SMB share on the LOCAL NETWORK (and over your tailnet if
# you use one), so the family can browse it from the iOS/iPadOS Files app:
#   Browse -> Connect to Server -> smb://<this-machine>.local
# It is NOT exposed to the internet (a home router/NAT does not forward inbound SMB).
#
# Safety choices:
#   * read only = yes            (the family can view/copy, never modify or delete)
#   * authenticated (no guest)   (a dedicated, login-less SMB account with a password)
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

log "This will configure a READ-ONLY SMB share for the local network, using sudo:"
printf '    - install: samba\n'
printf '    - share   [%s]  ->  %s   (read only, owner %s:%s)\n' "$SHARE_NAME" "$SERVE_PATH" "$SERVE_OWNER" "$SERVE_GROUP"
printf '    - reachable on the local network (and your tailnet); allowed through the firewall on 445\n'
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

log "Writing the managed share config"
sudo tee "$MANAGED" >/dev/null <<EOF
# Managed by archive-serve-setup.sh — edit SERVE_PATH/SAMBA_USER and re-run, or edit here and
# 'sudo systemctl restart smbd'. Serves the archive READ-ONLY on the local network (and tailnet).
[global]
   server string = Digital Archive (read-only)
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

# Allow SMB through the host firewall (if ufw is active) so devices on the local network can reach
# it. A home router/NAT still keeps it off the public internet.
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow Samba >/dev/null 2>&1 || sudo ufw allow 445/tcp >/dev/null 2>&1 || true
  info "allowed SMB through ufw for the local network."
fi

# ---- Connection instructions -----------------------------------------------------------------
host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ts_name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
log "Done — the archive is shared READ-ONLY on the local network."
cat <<EOF
    On each iPhone/iPad (on the same home Wi-Fi):
      1. Open the Files app -> Browse.
      2. Tap the "..." menu (top-right) -> Connect to Server.
      3. Enter:   smb://${host_short}.local        (or  smb://${lan_ip:-<this-machine-LAN-IP>} )
      4. Connect As: Registered User
         Name:     ${SAMBA_USER}
         Password: $( [[ -n "$GENERATED_PW" ]] && echo "${GENERATED_PW}   (save this now)" || echo "the password you just set" )
      5. Open the "${SHARE_NAME}" share.

    Notes:
      - The share is READ-ONLY and password-protected: the family can view and copy, never change/delete.
      - It is on the local network, not the public internet (your router/NAT blocks inbound SMB).
      - You can also reach it remotely over your tailnet at:  smb://${ts_name:-<your-tailscale-name>}
      - If "smb://${host_short}.local" doesn't resolve on a device, use the LAN IP shown above.
      - Re-run archive-index after new ingests so search stays current (see archive-search-setup.sh).
EOF
[[ -n "$GENERATED_PW" ]] && warn "The generated password above is shown only once. Save it now."
