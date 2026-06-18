#!/usr/bin/env bash
#
# archive-czkawka-setup.sh — find duplicate & similar files in the archive, via a read-only web GUI.
#
# Deploys jlesage/czkawka (czkawka's GUI in the browser) as a PINNED Docker Compose stack. czkawka
# finds DUPLICATE files by content and visually-SIMILAR images — across devices, even when they're
# named or timestamped differently. It complements the others (Immich=photos, Paperless=docs,
# recoll=search, copyparty=browse); czkawka is "spot the duplicates".
#
# It is a REPORTING tool here, made safe for irreplaceable data: the archive is mounted into the
# container READ-ONLY (:ro), so czkawka can scan and list duplicates but can NEVER delete or change a
# master — delete attempts simply fail at the filesystem. Any real culling is a separate, deliberate
# step, never casual clicks in a browser. It listens on LOOPBACK only; publish it (behind the same
# family password as search) with archive-proxy-setup.sh. Config/cache live on the OS disk, off the
# archive budget, and it joins the shared 'memorial' network.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${CZKAWKA_DIR:-/srv/apps/czkawka}"
CZKAWKA_VERSION="${CZKAWKA_VERSION:-}"          # empty = auto-resolve the latest jlesage image tag
CZKAWKA_PORT="${CZKAWKA_PORT:-5800}"            # published on 127.0.0.1 only; Caddy fronts it
CZKAWKA_IMAGE="${CZKAWKA_IMAGE:-jlesage/czkawka}"
FALLBACK_VERSION="v26.03.1"                      # used only if the tag lookup fails
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"
ARCHIVE_ROOT="/srv/archive"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: CZKAWKA_VERSION (pin a tag), CZKAWKA_DIR, CZKAWKA_IMAGE, CZKAWKA_PORT.
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
[[ -d "$ARCHIVE_ROOT" ]] || warn "Archive root ${ARCHIVE_ROOT} not found yet — czkawka will start, but it will scan an empty archive until it exists."

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# Resolve the jlesage image tag to pin (date-based, e.g. v26.03.1 — independent of czkawka's own version).
if [[ -z "$CZKAWKA_VERSION" ]]; then
  info "Resolving the latest jlesage/czkawka image tag..."
  CZKAWKA_VERSION="$(curl -fsSL "https://hub.docker.com/v2/repositories/${CZKAWKA_IMAGE}/tags/?page_size=100" 2>/dev/null \
    | grep -oE '"name":"v[0-9.]+"' | sed 's/.*"\(v[0-9.]*\)"/\1/' | sort -V | tail -1)"
  [[ -n "$CZKAWKA_VERSION" ]] || { CZKAWKA_VERSION="$FALLBACK_VERSION"; warn "Tag lookup failed; using ${CZKAWKA_VERSION}."; }
fi
IMAGE_TAG="$CZKAWKA_VERSION"
uid="$(id -u)"; gid="$(id -g)"
tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')"
host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will deploy czkawka ${CZKAWKA_VERSION} with Docker, using sudo:"
printf '    - a duplicate/similar-file finder for %s (mounted :ro — masters can never be changed)\n' "$ARCHIVE_ROOT"
printf '    - app config/cache: %s/config   (OS disk, off the archive budget)\n' "$APP_DIR"
printf '    - listens on 127.0.0.1:%s ONLY — publish it with archive-proxy-setup.sh (dupes.<domain>)\n' "$CZKAWKA_PORT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating ${APP_DIR} (config/cache)"
sudo mkdir -p "$APP_DIR/config"
sudo chown -R "$uid:$gid" "$APP_DIR/config"

log "Ensuring the shared '${DOCKER_NET}' network exists"
sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NET" >/dev/null

log "Writing docker-compose.yml (pinned ${IMAGE_TAG}, archive READ-ONLY, loopback-only)"
sudo tee "$APP_DIR/docker-compose.yml" >/dev/null <<EOF
# Managed by archive-czkawka-setup.sh — read-only duplicate finder, fronted by Caddy.
services:
  czkawka:
    image: ${CZKAWKA_IMAGE}:${IMAGE_TAG}
    container_name: czkawka
    environment:
      USER_ID: "${uid}"
      GROUP_ID: "${gid}"
      TZ: "${tz}"
      KEEP_APP_RUNNING: "1"           # relaunch the GUI if it's closed, so the page always works
    ports:
      - "127.0.0.1:${CZKAWKA_PORT}:5800"   # loopback only — Caddy publishes it on the LAN
    volumes:
      - ${APP_DIR}/config:/config            # GUI config + state (off the archive)
      - ${ARCHIVE_ROOT}:/storage:ro          # the archive, READ-ONLY: scan/report only, never delete
    networks:
      - ${DOCKER_NET}
    restart: unless-stopped
    stop_grace_period: 15s
networks:
  ${DOCKER_NET}:
    external: true
EOF

log "Validating the compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

log "Starting czkawka (first run pulls the image — a minute or two)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — czkawka is starting."
cat <<EOF
    It listens on 127.0.0.1:${CZKAWKA_PORT} only. Make it reachable (behind the same password as search)
    by running the front door:
        ./manage.sh   ->  Install  ->  One-URL front door     (or:  bash archive-proxy-setup.sh)
    then open    http://dupes.home/    (after the AdGuard rewrite the proxy step prints).

    Quick local check on the box itself:
        curl -sI http://127.0.0.1:${CZKAWKA_PORT}/ | head -1     (expect HTTP 200)

    How to use it (it's a normal czkawka GUI, in your browser):
      1. In the app, add the folder to scan:  /storage/incoming   (the verified master copies).
         Tip: exclude /storage/.recoll, /storage/.derived, /storage/images, /storage/.plocate.db
         (those are the search index, derived data, and raw disk images — not originals).
      2. Pick a tool — "Duplicate Files" (same content, any name) or "Similar Images" — and Search.
      3. Review the groups. czkawka can also find similar videos/music, empty files, etc.
      See czkawka's guide: https://github.com/qarmin/czkawka/blob/master/instructions/Instruction.md

    Safety:
      - The archive is mounted READ-ONLY. czkawka can FIND duplicates but can NEVER delete or change a
        master — any delete/move action will fail. Cull duplicates, if ever, by a separate deliberate
        step against a writable copy — never from here.
      - App data is in ${APP_DIR}/config on the OS disk (regenerable; not part of the verified backup).
      - Manage:  archive-apps status   ·   cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Reachable on ${host_short}.local / ${lan_ip:-the LAN IP} only via the Caddy front door.
EOF
