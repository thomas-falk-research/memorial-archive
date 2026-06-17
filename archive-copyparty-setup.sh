#!/usr/bin/env bash
#
# archive-copyparty-setup.sh — a read-only web file browser for the family (copyparty).
#
# Deploys copyparty as a PINNED Docker Compose stack: a plain-URL way to browse and download ANY
# file in the archive from a phone/computer browser, with folder navigation and thumbnails — no app
# and no SMB "Connect to Server" needed. It complements the others (Immich = photos, Paperless =
# documents, recoll = search); copyparty is "browse/download everything".
#
# It is STRICTLY READ-ONLY, enforced in depth so the irreplaceable masters can never be changed:
#   1. the archive is bind-mounted into the container READ-ONLY (:ro) — the container physically
#      cannot write to it, regardless of any app config;
#   2. copyparty's volume grants only 'r' (read) — no upload/move/delete;
#   3. it listens on LOOPBACK only (127.0.0.1) — nothing reaches it except the Caddy front door;
#   4. its index/thumbnail cache lives OFF the archive (in its own cfg dir on the OS disk).
# Publish it to the family with archive-proxy-setup.sh, which puts it behind a password at
# files.<domain> (reusing the same 'family' login as search).
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${COPYPARTY_DIR:-/srv/apps/copyparty}"
COPYPARTY_VERSION="${COPYPARTY_VERSION:-}"     # empty = auto-resolve the latest release
COPYPARTY_PORT="${COPYPARTY_PORT:-3923}"       # published on 127.0.0.1 only; Caddy fronts it
COPYPARTY_IMAGE="${COPYPARTY_IMAGE:-copyparty/ac}"   # 'ac' = includes ffmpeg for media thumbnails
FALLBACK_VERSION="v1.20.16"                     # used only if the release lookup fails
ARCHIVE_ROOT="/srv/archive"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: COPYPARTY_VERSION (pin a tag), COPYPARTY_DIR, COPYPARTY_IMAGE.
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
[[ -d "$ARCHIVE_ROOT" ]] || warn "Archive root ${ARCHIVE_ROOT} not found yet — copyparty will start, but it will show an empty archive until it exists."

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# Resolve the version to pin. copyparty's git tags are vX.Y.Z; the Docker image tag drops the 'v'.
if [[ -z "$COPYPARTY_VERSION" ]]; then
  info "Resolving the latest copyparty release..."
  COPYPARTY_VERSION="$(git ls-remote --tags --refs https://github.com/9001/copyparty 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$COPYPARTY_VERSION" ]] || { COPYPARTY_VERSION="$FALLBACK_VERSION"; warn "Release lookup failed; using ${COPYPARTY_VERSION}."; }
fi
IMAGE_TAG="${COPYPARTY_VERSION#v}"
uid="$(id -u)"; gid="$(id -g)"
host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will deploy copyparty ${COPYPARTY_VERSION} with Docker, using sudo:"
printf '    - a READ-ONLY web file browser for %s (bind-mounted :ro — masters can never change)\n' "$ARCHIVE_ROOT"
printf '    - app data (config + thumbnail/index cache): %s/cfg   (OS disk, off the archive budget)\n' "$APP_DIR"
printf '    - listens on 127.0.0.1:%s ONLY — publish it with archive-proxy-setup.sh (files.<domain>)\n' "$COPYPARTY_PORT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating ${APP_DIR} (config + history cache)"
sudo mkdir -p "$APP_DIR/cfg/hist"
sudo chown -R "$uid:$gid" "$APP_DIR/cfg"

log "Writing copyparty.conf (one read-only volume; cache kept off the archive)"
# /cfg/*.conf is auto-loaded by the image. The archive is mounted at /w/archive (read-only); we serve
# it at URL "/" with 'r: *' = read for everyone who reaches the port (only Caddy does, behind a
# password). No w/m/d anywhere, so no upload/move/delete. hist (index + thumbnails) -> /cfg/hist.
sudo tee "$APP_DIR/cfg/copyparty.conf" >/dev/null <<'CONF'
[global]
  hist: /cfg/hist

[/]
  /w/archive
  accs:
    r: *
CONF
sudo chown "$uid:$gid" "$APP_DIR/cfg/copyparty.conf"

log "Writing docker-compose.yml (pinned ${IMAGE_TAG}, archive READ-ONLY, loopback-only)"
sudo tee "$APP_DIR/docker-compose.yml" >/dev/null <<EOF
# Managed by archive-copyparty-setup.sh — read-only web file browser, fronted by Caddy.
services:
  copyparty:
    image: ${COPYPARTY_IMAGE}:${IMAGE_TAG}
    container_name: copyparty
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${COPYPARTY_PORT}:3923"      # loopback only — Caddy publishes it on the LAN
    volumes:
      - ${ARCHIVE_ROOT}:/w/archive:ro            # the archive, READ-ONLY (defense in depth)
      - ${APP_DIR}/cfg:/cfg                       # config + thumbnail/index cache (off the archive)
    restart: unless-stopped
    stop_grace_period: 15s
EOF

log "Validating the compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

log "Starting copyparty (first run pulls the image — a minute or two)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — copyparty is starting."
cat <<EOF
    It listens on 127.0.0.1:${COPYPARTY_PORT} only. Make it reachable for the family (behind the
    same password as search) by running the front door:
        ./manage.sh   ->  Install  ->  One-URL front door     (or:  bash archive-proxy-setup.sh)
    then open    http://files.home/    (after the AdGuard rewrite the proxy step prints).

    Quick local check on the box itself:
        curl -sI http://127.0.0.1:${COPYPARTY_PORT}/ | head -1     (expect HTTP 200)

    Notes:
      - READ-ONLY in depth: the archive is mounted :ro, the volume grants only 'r', and it listens on
        loopback. The family can browse and download; they can never change or delete a master.
      - App data (config + thumbnail cache) is in ${APP_DIR}/cfg on the OS disk — regenerable, and NOT
        part of the verified backup (there's nothing irreplaceable here; the originals are the archive).
      - Manage:  cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Reachable on ${host_short}.local / ${lan_ip:-the LAN IP} only via the Caddy front door.
EOF
