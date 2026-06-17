#!/usr/bin/env bash
#
# archive-immich-setup.sh — self-hosted photos & videos (Immich) for the family.
#
# Deploys Immich as a PINNED Docker Compose stack. App data (Postgres, thumbnails, ML cache) lives
# on the OS disk under /srv/apps/immich — off the 2 TB archive budget and regenerable. The archive's
# photos are exposed to Immich as a READ-ONLY external library at /mnt/archive: Immich indexes them
# in place, never copying or modifying your masters. Reachable on the local network (and your
# tailnet) at :2283; the Immich iOS/iPadOS app points at the same address.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-immich-setup.sh`). Needs Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${IMMICH_DIR:-/srv/apps/immich}"
IMMICH_VERSION="${IMMICH_VERSION:-}"          # empty = auto-resolve the latest release
IMMICH_PORT="${IMMICH_PORT:-2283}"
FALLBACK_VERSION="v2.7.5"                      # used only if the release lookup fails
ARCHIVE_ROOT="/srv/archive"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: IMMICH_VERSION (pin a tag), IMMICH_PORT (default 2283), IMMICH_DIR.
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
command -v curl >/dev/null 2>&1 || die "curl is required."

if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
[[ -d "$ARCHIVE_ROOT" ]] || warn "Archive root ${ARCHIVE_ROOT} not found yet — Immich will start, but the external library will be empty until it exists."

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# Resolve the version to pin.
if [[ -z "$IMMICH_VERSION" ]]; then
  info "Resolving the latest Immich release..."
  IMMICH_VERSION="$(git ls-remote --tags --refs https://github.com/immich-app/immich 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$IMMICH_VERSION" ]] || { IMMICH_VERSION="$FALLBACK_VERSION"; warn "Release lookup failed; using ${IMMICH_VERSION}."; }
fi

# Detect a sane address to show + check RAM (Immich's ML likes a few GB).
host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
mem_gib="$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"

log "This will deploy Immich ${IMMICH_VERSION} with Docker, using sudo:"
printf '    - app data (DB, thumbnails, ML cache): %s   (on the OS disk, off the archive budget)\n' "$APP_DIR"
printf '    - photos: READ-ONLY external library of %s (indexed in place, never modified)\n' "$ARCHIVE_ROOT"
printf '    - reachable on the local network + tailnet at port %s\n' "$IMMICH_PORT"
printf '    - system RAM detected: %s GiB (Immich ML is happiest with >= 6 GiB; see notes if low)\n' "$mem_gib"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating ${APP_DIR}"
sudo mkdir -p "$APP_DIR" "$APP_DIR/library" "$APP_DIR/postgres"

log "Fetching Immich's official compose (pinned ${IMMICH_VERSION})"
sudo curl -fsSL "https://github.com/immich-app/immich/releases/download/${IMMICH_VERSION}/docker-compose.yml" \
  -o "$APP_DIR/docker-compose.yml" || die "Could not download Immich's docker-compose.yml for ${IMMICH_VERSION}."

log "Writing .env (reuse any existing DB password; pin the resolved version)"
# Reuse the DB password on re-run, but ALWAYS write the resolved IMMICH_VERSION. Immich pins its
# image from .env (${IMMICH_VERSION:-release}), so if we kept a stale .env, re-running to update
# would silently keep the OLD image even though a newer compose was just downloaded.
db_pw=""
if [[ -f "$APP_DIR/.env" ]]; then
  db_pw="$(sudo sed -n 's/^DB_PASSWORD=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
  old_ver="$(sudo sed -n 's/^IMMICH_VERSION=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
  [[ -n "$old_ver" && "$old_ver" != "$IMMICH_VERSION" ]] && info "updating the pin ${old_ver} -> ${IMMICH_VERSION}."
fi
if [[ -n "$db_pw" ]]; then info "reusing the existing database password."
else db_pw="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)"; fi
sudo tee "$APP_DIR/.env" >/dev/null <<EOF
# Managed by archive-immich-setup.sh
UPLOAD_LOCATION=${APP_DIR}/library
DB_DATA_LOCATION=${APP_DIR}/postgres
IMMICH_VERSION=${IMMICH_VERSION}
DB_PASSWORD=${db_pw}
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
EOF
sudo chmod 600 "$APP_DIR/.env"
# Expose the archive read-only to immich-server so it can be added as an external library.
sudo tee "$APP_DIR/docker-compose.override.yml" >/dev/null <<EOF
# Managed by archive-immich-setup.sh — mount the archive READ-ONLY for an in-place external library.
services:
  immich-server:
    volumes:
      - ${ARCHIVE_ROOT}:/mnt/archive:ro
EOF

log "Validating the merged compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow "${IMMICH_PORT}/tcp" >/dev/null 2>&1 || true
  info "opened port ${IMMICH_PORT} in ufw for the local network."
fi

log "Starting Immich (first run pulls images — a few minutes)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — Immich is starting."
cat <<EOF
    Open it (give it a minute on first start):
        http://${host_short}.local:${IMMICH_PORT}/        (or  http://${lan_ip:-<LAN-IP>}:${IMMICH_PORT}/ )

    First-time setup (in the browser):
      1. Create the admin account (the first account is the administrator).
      2. Administration -> External Libraries -> add a library with path:  /mnt/archive
         Immich will scan the archive's photos/videos read-only, in place (no copy).
      3. Add family logins under Administration -> Users.
      4. Install the "Immich" app on each iPhone/iPad and point it at the same address.

    Notes:
      - The archive is mounted READ-ONLY: Immich can never alter or delete your masters.
      - App data lives in ${APP_DIR} (OS disk). Originals stay in ${ARCHIVE_ROOT} (+ your backup).
      - 'archive-backup' also dumps Immich's database (albums/people/tags) and any uploaded
        originals to /srv/backup/apps/immich, with a RESTORE.txt alongside.
      - If the mini-PC is low on RAM, disable the ML container:
          cd ${APP_DIR} && sudo docker compose stop immich-machine-learning
        (faces/smart-search stop; browsing and albums keep working.)
      - Manage:  cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
EOF
