#!/usr/bin/env bash
#
# archive-kopia-setup.sh — a Kopia REPOSITORY SERVER on the box, so the family's Windows PCs can
# back themselves up onto the archive box (their own files — Documents, Pictures, Desktop, …).
#
# This is the SECOND backup flow, separate from the archive's own off-site backup:
#   * archive-backup / archive-restic  ->  the archive (the deceased's files) goes OFF-SITE.
#   * THIS (Kopia server)              ->  the family's live PCs back up INTO the box (box-only).
#
# Each PC runs KopiaUI (free, Windows) and connects to this server with its own username/password
# over TLS; Kopia encrypts + deduplicates, so many dated restore points fit in little space. The PC
# backups live on the box's INTERNAL disk under /srv/pc-backups — physically separate from the
# irreplaceable 2 TB archive masters, and off the archive's space budget.
#
# Deployed as a PINNED Docker Compose stack (consistent with the other apps). Run as a REGULAR user
# with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh) and openssl.
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${KOPIA_DIR:-/srv/apps/kopia}"
PCBACKUP_DIR="${PCBACKUP_DIR:-/srv/pc-backups}"          # PC backups land here (internal disk)
KOPIA_PORT="${KOPIA_PORT:-51515}"                        # the port each PC's KopiaUI connects to
KOPIA_IMAGE="${KOPIA_IMAGE:-kopia/kopia}"
KOPIA_VERSION="${KOPIA_VERSION:-}"                       # empty = resolve the latest stable release
FALLBACK_VERSION="0.18.2"                                # only if release lookup fails (else ':latest')
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  Stands up a Kopia repository server so the family's Windows PCs (KopiaUI) back up onto the box.
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: KOPIA_VERSION (pin a tag), KOPIA_DIR, PCBACKUP_DIR, KOPIA_PORT.
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
command -v openssl >/dev/null 2>&1 || die "openssl is required (to make the server's TLS certificate)."
sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# Resolve the version to pin (git tags are vX.Y.Z; the image tag drops the 'v'). Stable only.
if [[ -z "$KOPIA_VERSION" ]]; then
  info "Resolving the latest stable Kopia release..."
  KOPIA_VERSION="$(git ls-remote --tags --refs https://github.com/kopia/kopia 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
fi
if [[ -n "$KOPIA_VERSION" ]]; then
  IMAGE_TAG="${KOPIA_VERSION#v}"
elif [[ -n "$FALLBACK_VERSION" ]]; then
  IMAGE_TAG="$FALLBACK_VERSION"; warn "Release lookup failed; using ${KOPIA_IMAGE}:${IMAGE_TAG}."
else
  IMAGE_TAG="latest"; warn "Release lookup failed; using ${KOPIA_IMAGE}:latest (unpinned)."
fi

host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ts_name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"

log "This will deploy a Kopia repository server (${KOPIA_IMAGE}:${IMAGE_TAG}) with Docker, using sudo:"
printf '    - the family Windows PCs back up INTO the box (KopiaUI -> this server, encrypted)\n'
printf '    - PC backups stored on the INTERNAL disk: %s   (off the 2 TB archive budget)\n' "$PCBACKUP_DIR"
printf '    - reachable on the LAN / tailnet at port %s (TLS, per-PC logins)\n' "$KOPIA_PORT"
printf '    - app config/state: %s\n' "$APP_DIR"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating directories"
sudo mkdir -p "$APP_DIR/config" "$APP_DIR/cache" "$APP_DIR/logs" "$PCBACKUP_DIR/repo"

log "Writing .env (reuse existing secrets on re-run; NEVER rotate the repo password)"
# The repo password encrypts EVERYTHING; rotating it would orphan all PC backups, so a re-run reuses
# it. The server-control password is the admin channel used to reload users.
repo_pw=""; ctrl_pw=""; fresh_repo=false
if sudo test -f "$APP_DIR/.env"; then
  repo_pw="$(sudo sed -n 's/^KOPIA_REPO_PASSWORD=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
  ctrl_pw="$(sudo sed -n 's/^KOPIA_SERVER_CONTROL_PASSWORD=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
fi
[[ -n "$repo_pw" ]] || { repo_pw="$(openssl rand -base64 24 2>/dev/null | tr -d '\n')"; fresh_repo=true; }
[[ -n "$ctrl_pw" ]] || ctrl_pw="$(openssl rand -base64 18 2>/dev/null | tr -d '\n')"
sudo tee "$APP_DIR/.env" >/dev/null <<EOF
# Managed by archive-kopia-setup.sh — secrets; keep private (chmod 600).
KOPIA_REPO_PASSWORD=${repo_pw}
KOPIA_SERVER_CONTROL_PASSWORD=${ctrl_pw}
EOF
sudo chmod 600 "$APP_DIR/.env"

log "Generating the server's TLS certificate (self-signed; clients pin its fingerprint)"
# Pre-generate with openssl so the compose 'server start' command is identical on every restart
# (kopia's own --tls-generate-cert must be dropped after the first start; pre-generating avoids that).
if ! sudo test -f "$APP_DIR/config/tls.cert"; then
  san="DNS:${host_short},DNS:${host_short}.local"
  [[ -n "$lan_ip" ]] && san="${san},IP:${lan_ip}"
  [[ -n "$ts_name" ]] && san="${san},DNS:${ts_name}"
  sudo openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$APP_DIR/config/tls.key" -out "$APP_DIR/config/tls.cert" \
    -subj "/CN=memorial-archive-kopia" -addext "subjectAltName=${san}" >/dev/null 2>&1 \
    || die "openssl could not generate the TLS certificate."
  sudo chmod 640 "$APP_DIR/config/tls.key"; sudo chmod 644 "$APP_DIR/config/tls.cert"
fi
FINGERPRINT="$(sudo openssl x509 -in "$APP_DIR/config/tls.cert" -noout -fingerprint -sha256 \
  | sed 's/://g' | cut -f2 -d= | tr '[:upper:]' '[:lower:]')"

log "Ensuring the shared '${DOCKER_NET}' network exists"
sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NET" >/dev/null

log "Writing docker-compose.yml (pinned: ${KOPIA_IMAGE}:${IMAGE_TAG})"
# Secrets come from ./.env (compose auto-reads it). The server connects to the filesystem repository
# mounted at /repository and serves it over TLS; clients authenticate as repository users.
sudo tee "$APP_DIR/docker-compose.yml" >/dev/null <<EOF
# Managed by archive-kopia-setup.sh — Kopia repository server for the family's Windows PC backups.
services:
  kopia:
    image: ${KOPIA_IMAGE}:${IMAGE_TAG}
    container_name: kopia
    hostname: ${host_short}
    command:
      - server
      - start
      - --tls-cert-file=/app/config/tls.cert
      - --tls-key-file=/app/config/tls.key
      - --address=0.0.0.0:51515
      - --server-control-username=control
    environment:
      KOPIA_PASSWORD: "\${KOPIA_REPO_PASSWORD}"
      KOPIA_SERVER_CONTROL_PASSWORD: "\${KOPIA_SERVER_CONTROL_PASSWORD}"
    ports:
      - "${KOPIA_PORT}:51515"            # reachable by the PCs on the LAN / tailnet (TLS)
    volumes:
      - ./config:/app/config
      - ./cache:/app/cache
      - ./logs:/app/logs
      - ${PCBACKUP_DIR}/repo:/repository  # the PC-backup repository (internal disk)
    networks:
      - default
      - ${DOCKER_NET}
    restart: unless-stopped
networks:
  ${DOCKER_NET}:
    external: true
EOF

log "Validating the compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup. Check ${APP_DIR}."

# Initialise the filesystem repository ONCE (writes /app/config/repository.config that the server uses).
if ! sudo test -f "$APP_DIR/config/repository.config"; then
  log "Creating the encrypted repository at ${PCBACKUP_DIR}/repo (first run)"
  ( cd "$APP_DIR" && sudo docker compose run --rm kopia repository create filesystem --path=/repository ) \
    || die "Could not create the Kopia repository. Check Docker and ${PCBACKUP_DIR}."
  log "Enabling per-user access control (each PC sees only its own backups)"
  ( cd "$APP_DIR" && sudo docker compose run --rm kopia server acl enable ) >/dev/null 2>&1 \
    || warn "Could not enable ACLs now; add them later with 'archive-pc-backup' if needed."
fi

log "Starting the Kopia server"
( cd "$APP_DIR" && sudo docker compose up -d )

# Open the port through ufw (if active) for the local network. The router/NAT still blocks the internet.
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow "${KOPIA_PORT}/tcp" >/dev/null 2>&1 || true
  info "opened port ${KOPIA_PORT} in ufw for the local network."
fi

log "Installing /usr/local/bin/archive-pc-backup (add/list PCs, show connection details)"
sudo tee /usr/local/bin/archive-pc-backup >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-pc-backup — manage which family PCs may back up to the box, and show the details each PC
# needs in KopiaUI. Wraps the Kopia repository server. Needs sudo (it drives Docker).
set -uo pipefail
APP_DIR="${KOPIA_DIR:-/srv/apps/kopia}"
KOPIA_PORT="${KOPIA_PORT:-51515}"
[[ -f "$APP_DIR/docker-compose.yml" ]] || { echo "Kopia server not installed (run archive-kopia-setup.sh)." >&2; exit 1; }
dc() { ( cd "$APP_DIR" && sudo docker compose "$@" ); }
sanitize() { printf '%s' "$1" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'; }

lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
fp="$(sudo openssl x509 -in "$APP_DIR/config/tls.cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/://g' | cut -f2 -d= | tr '[:upper:]' '[:lower:]')"

show_info() {
  cat <<EOF

  In KopiaUI on the Windows PC:  "Connect To Repository Server"
    Server URL:        https://${lan_ip:-<box-LAN-IP>}:${KOPIA_PORT}
    Trusted fingerprint (SHA256):
        ${fp:-<run on the box>}
    Then enter the PC's username and password (create one with: archive-pc-backup add <pc-name>).
  (The PC must reach the box on the home network or over Tailscale.)
EOF
}

case "${1:-info}" in
  add)
    name="$(sanitize "${2:-}")"; [[ -n "$name" ]] || { echo "Usage: archive-pc-backup add <pc-name>   (e.g. moms-laptop)" >&2; exit 2; }
    pw="$(openssl rand -base64 15 2>/dev/null | tr -d '\n')"
    echo "Creating backup login '${name}@${name}'..."
    if dc exec -T kopia kopia server user add "${name}@${name}" --user-password="$pw" >/dev/null 2>&1; then
      dc restart kopia >/dev/null 2>&1 || true     # reload so the new login works immediately
      cat <<EOF
Added. Give these to that PC (write them down):
    Username:    ${name}
    Hostname:    ${name}        (set BOTH in KopiaUI so it matches)
    Password:    ${pw}
EOF
      show_info
    else
      echo "Could not add the user. Is the server running? (archive-pc-backup status)" >&2; exit 1
    fi ;;
  list)    dc exec -T kopia kopia server user list 2>/dev/null || { echo "Could not list users (is the server up?)." >&2; exit 1; } ;;
  remove)
    name="$(sanitize "${2:-}")"; [[ -n "$name" ]] || { echo "Usage: archive-pc-backup remove <pc-name>" >&2; exit 2; }
    if dc exec -T kopia kopia server user delete "${name}@${name}" >/dev/null 2>&1; then
      dc restart kopia >/dev/null 2>&1 || true; echo "Removed ${name}."
    else
      echo "Could not remove ${name}." >&2; exit 1
    fi ;;
  status)  dc ps ;;
  info|"") show_info ;;
  -h|--help) echo "Usage: archive-pc-backup [add <pc>|remove <pc>|list|status|info]"; ;;
  *) echo "Usage: archive-pc-backup [add <pc>|remove <pc>|list|status|info]" >&2; exit 2 ;;
esac
SCRIPT
sudo chmod +x /usr/local/bin/archive-pc-backup

log "Done — the PC-backup server is running."
cat <<EOF
    ${host_short} is now a Kopia backup server for the family's Windows PCs.

    1) On the box, create a login for each PC:
           archive-pc-backup add moms-laptop
       (it prints the username/password + the server URL and fingerprint to enter in KopiaUI)

    2) On each Windows PC: install KopiaUI (https://kopia.io/docs/installation/), choose
       "Connect To Repository Server", and enter the URL, fingerprint, username and password.
       Server URL:  https://${lan_ip:-<box-LAN-IP>}:${KOPIA_PORT}
       Fingerprint: ${FINGERPRINT}

    Notes:
      - PC backups are stored at ${PCBACKUP_DIR} on the INTERNAL disk (off the archive budget,
        separate from the masters). Watch its free space (archive-doctor reports it).
      - The repository password is in ${APP_DIR}/.env (chmod 600). Like the restic passphrase it
        CANNOT be reset without orphaning the backups — record it off the box.
      - Managed with the other apps:  archive-apps status   ·   archive-pc-backup status
EOF

# Printed LAST (and only when freshly generated) so this un-resettable secret can't get buried above
# the notes or under a later script's output. On a re-run the password is reused, never reprinted.
if [[ "$fresh_repo" == true ]]; then
  printf '\n\033[1;33m================================ RECORD THIS NOW ================================\033[0m\n'
  printf '  Kopia repository password (also saved, mode 600, at %s):\n\n' "$APP_DIR/.env"
  printf '      \033[1m%s\033[0m\n\n' "$repo_pw"
  printf '  Keep a copy OFF the box (password manager / sealed envelope). Like the restic passphrase\n'
  printf '  it CANNOT be reset: without it the Windows-PC backups in %s are unrecoverable.\n' "$PCBACKUP_DIR"
  printf '\033[1;33m================================================================================\033[0m\n'
fi
