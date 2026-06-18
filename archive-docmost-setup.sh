#!/usr/bin/env bash
#
# archive-docmost-setup.sh — a private family wiki / notes space (Docmost).
#
# Deploys Docmost as a PINNED Docker Compose stack (the app + its own PostgreSQL + Redis): a place for
# the family to WRITE — a biography, memories, and notes that organise the deceased's affairs (accounts,
# documents, to-dos). Unlike the rest of the suite (which is read-only), this app is read-WRITE and is
# the one place family members create content, so its database is irreplaceable: archive-backup dumps it.
#
# It has its OWN logins (each family member gets an account), so — like Immich/Paperless — it is fronted
# by Caddy WITHOUT an extra password. App data (Postgres + uploads + Redis) lives on the OS disk under
# /srv/apps/docmost, off the archive budget. Listens on loopback only; joins the shared 'memorial' net.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${DOCMOST_DIR:-/srv/apps/docmost}"
DOCMOST_VERSION="${DOCMOST_VERSION:-}"          # empty = auto-resolve the latest stable release
DOCMOST_PORT="${DOCMOST_PORT:-3000}"            # published on 127.0.0.1 only; Caddy fronts it
DOCMOST_IMAGE="${DOCMOST_IMAGE:-docmost/docmost}"
PG_IMAGE="${PG_IMAGE:-postgres:16-alpine}"      # pinned MAJOR — never change it on an existing DB
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
FALLBACK_VERSION="v0.90.1"                       # used only if the release lookup fails
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"
BASE_DOMAIN="${BASE_DOMAIN:-home}"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: DOCMOST_VERSION (pin a tag), DOCMOST_DIR, DOCMOST_URL, DOCMOST_PORT, BASE_DOMAIN.
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

if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
DOCMOST_URL="${DOCMOST_URL:-http://docmost.${BASE_DOMAIN}}"

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# Resolve the version to pin. Git tags are vX.Y.Z; the image tag drops the leading 'v'. Pre-releases
# (alpha/beta/rc) are excluded by the strict match, so this tracks the latest STABLE.
if [[ -z "$DOCMOST_VERSION" ]]; then
  info "Resolving the latest stable Docmost release..."
  DOCMOST_VERSION="$(git ls-remote --tags --refs https://github.com/docmost/docmost 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$DOCMOST_VERSION" ]] || { DOCMOST_VERSION="$FALLBACK_VERSION"; warn "Release lookup failed; using ${DOCMOST_VERSION}."; }
fi
DOCMOST_VERSION="v${DOCMOST_VERSION#v}"
IMAGE_TAG="${DOCMOST_VERSION#v}"
host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will deploy Docmost ${DOCMOST_VERSION} with Docker, using sudo:"
printf '    - a read-WRITE family wiki/notes app + its own PostgreSQL + Redis\n'
printf '    - app data (DB, uploads, redis): %s   (OS disk, off the archive budget)\n' "$APP_DIR"
printf '    - URL it builds links with (APP_URL): %s\n' "$DOCMOST_URL"
printf '    - listens on 127.0.0.1:%s ONLY — publish it with archive-proxy-setup.sh (docmost.<domain>)\n' "$DOCMOST_PORT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating ${APP_DIR}"
sudo mkdir -p "$APP_DIR"

log "Writing .env (reuse the existing secret + DB password on re-run; pin the version + URL)"
# Reuse the generated secret and DB password if present, so a re-run (update/repair) never invalidates
# sessions or locks the app out of its own database.
db_pw=""; app_secret=""
if sudo test -f "$APP_DIR/.env"; then
  db_pw="$(sudo sed -n 's/^DOCMOST_DB_PASSWORD=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
  app_secret="$(sudo sed -n 's/^DOCMOST_APP_SECRET=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
fi
[[ -n "$db_pw" ]] || db_pw="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)"
[[ -n "$app_secret" ]] || app_secret="$(openssl rand -hex 32 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 64)"
sudo tee "$APP_DIR/.env" >/dev/null <<EOF
# Managed by archive-docmost-setup.sh — secrets; keep this file private (chmod 600).
DOCMOST_APP_URL=${DOCMOST_URL}
DOCMOST_APP_SECRET=${app_secret}
DOCMOST_DB_PASSWORD=${db_pw}
EOF
sudo chmod 600 "$APP_DIR/.env"

log "Ensuring the shared '${DOCKER_NET}' network exists"
sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NET" >/dev/null

log "Writing docker-compose.yml (pinned: docmost ${IMAGE_TAG}, ${PG_IMAGE}, ${REDIS_IMAGE})"
# Secrets come from the .env file above (compose auto-reads ./.env for ${...}). The app reaches its DB
# and Redis on the project's private 'default' network; it ALSO joins 'memorial' for the front door.
sudo tee "$APP_DIR/docker-compose.yml" >/dev/null <<EOF
# Managed by archive-docmost-setup.sh — family wiki/notes (read-WRITE), fronted by Caddy.
services:
  docmost:
    image: ${DOCMOST_IMAGE}:${IMAGE_TAG}
    container_name: docmost
    depends_on:
      - db
      - redis
    environment:
      APP_URL: "\${DOCMOST_APP_URL}"
      APP_SECRET: "\${DOCMOST_APP_SECRET}"
      DATABASE_URL: "postgresql://docmost:\${DOCMOST_DB_PASSWORD}@db:5432/docmost"
      REDIS_URL: "redis://redis:6379"
    ports:
      - "127.0.0.1:${DOCMOST_PORT}:3000"     # loopback only — Caddy publishes it on the LAN
    volumes:
      - docmost_storage:/app/data/storage    # uploaded attachments/images (backed up by archive-backup)
    networks:
      - default
      - ${DOCKER_NET}
    restart: unless-stopped
  db:
    image: ${PG_IMAGE}
    container_name: docmost-db
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: "\${DOCMOST_DB_PASSWORD}"
    volumes:
      - docmost_db:/var/lib/postgresql/data
    restart: unless-stopped
  redis:
    image: ${REDIS_IMAGE}
    container_name: docmost-redis
    volumes:
      - docmost_redis:/data
    restart: unless-stopped
volumes:
  docmost_storage:
  docmost_db:
  docmost_redis:
networks:
  ${DOCKER_NET}:
    external: true
EOF

log "Validating the compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

log "Starting Docmost (first run pulls images + initialises the database — a few minutes)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — Docmost is starting."
cat <<EOF
    IMPORTANT — set it up in the right order so logins work and nobody can grab the admin account:
      1. Run the front door + add the DNS rewrite it prints:
            ./manage.sh  ->  Install  ->  One-URL front door
         (Docmost is built to live at ${DOCMOST_URL}; reaching it by IP can break login cookies.)
      2. Open ${DOCMOST_URL} and CREATE THE ADMIN ACCOUNT FIRST (the first account becomes the owner).
         Do this promptly — before sharing the address — so no one else registers as owner.
      3. In Settings, set the workspace to invite-only, then invite the family.

    Local check on the box (give it a minute to migrate the DB):
        curl -sI http://127.0.0.1:${DOCMOST_PORT}/ | head -1     (expect HTTP 200 or a redirect)

    Notes:
      - This app is read-WRITE and its database is the family's own writing — it is backed up by
        'archive-backup' (a PostgreSQL dump + the uploads) into /srv/backup/apps/docmost, with a
        RESTORE.txt alongside. Run a backup after people start adding content.
      - Secrets (APP_SECRET, DB password) are in ${APP_DIR}/.env (chmod 600) — keep them; the DB dump
        is useless without being able to recreate the app.
      - If you must reach it by IP first, set DOCMOST_URL and re-run:  DOCMOST_URL=http://${lan_ip:-<IP>}:${DOCMOST_PORT} bash archive-docmost-setup.sh
      - Manage:  archive-apps status   ·   cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Reachable on ${host_short}.local / ${lan_ip:-the LAN IP} only via the Caddy front door.
EOF
