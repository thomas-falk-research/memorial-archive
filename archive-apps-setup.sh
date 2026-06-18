#!/usr/bin/env bash
#
# archive-apps-setup.sh — one place to manage all the family Docker apps.
#
# Installs the `archive-apps` command and creates a shared Docker network ("memorial"). Each app
# (Immich, Paperless, copyparty, czkawka, Stirling-PDF, docmost, ...) keeps its OWN Compose project
# under /srv/apps/<app>, so its data volumes are NEVER renamed or orphaned — archive-apps simply runs
# `docker compose` across all of them so you can see status, update/pull, tail logs, and restart
# everything from a single command instead of cd-ing into each app directory. That's the safe way to
# get a unified view: merging everything into one Compose project would re-prefix named volumes (e.g.
# Paperless's documents/database) and orphan them.
#
# The shared "memorial" network is groundwork: apps that opt in can talk to each other by name (and a
# future containerised front door can reach them without published ports). Joining it is per-app and
# additive; this script only creates the network.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-apps-setup.sh`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

APPS_ROOT="${APPS_ROOT:-/srv/apps}"
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Installs the 'archive-apps' command and creates the shared '${DOCKER_NET}' Docker network.
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

log "This will install (using sudo):"
printf '    - command to /usr/local/bin: archive-apps (manage every app: status/update/logs/restart)\n'
printf '    - a shared Docker network: %s (apps opt in; no app is moved or changed)\n' "$DOCKER_NET"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

log "Creating the shared Docker network '${DOCKER_NET}' (if missing)"
if sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
  info "network ${DOCKER_NET} already exists."
else
  sudo docker network create "$DOCKER_NET" >/dev/null && info "created network ${DOCKER_NET}."
fi

log "Installing the archive-apps command"
sudo tee /usr/local/bin/archive-apps >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-apps — manage every family Docker app from one place. Each app keeps its OWN Compose project
# under /srv/apps/<app> (data volumes are never renamed); this just runs `docker compose` across all of
# them. Default action (status) is read-only. Run as your normal user; it sudo's for Docker.
set -uo pipefail
APPS_ROOT="${APPS_ROOT:-/srv/apps}"
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"

c_grn=$'\033[1;32m'; c_cyn=$'\033[0;36m'; c_red=$'\033[1;31m'; c_rst=$'\033[0m'
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
command -v docker >/dev/null 2>&1 || { err "docker not found — run provision.sh first."; exit 1; }

# Discover installed apps = directories under APPS_ROOT that contain a docker-compose.yml.
mapfile -t APPS < <(find "$APPS_ROOT" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' 2>/dev/null | sort)

ensure_net() { sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NET" >/dev/null 2>&1 || true; }
run_all() {  # run `docker compose $@` in every app dir; keep going on error, return 1 if any failed
  local d rc=0
  for d in "${APPS[@]}"; do
    printf '\n%s=== %s ===%s\n' "$c_cyn" "${d##*/}" "$c_rst"
    ( cd "$d" && sudo docker compose "$@" ) || rc=1
  done
  return $rc
}

usage() {
  cat <<USAGE
archive-apps — manage all family Docker apps at once (each keeps its own Compose project)
  archive-apps status      show containers for every app (default; read-only)
  archive-apps update      pull newer images + recreate, for every app
  archive-apps pull        pull images only
  archive-apps up | down   start / stop every app
  archive-apps restart     restart every app
  archive-apps logs APP    follow one app's logs (Ctrl-C to stop)
  archive-apps list        list installed apps
USAGE
}

sub="${1:-status}"; [[ $# -gt 0 ]] && shift
case "$sub" in
  -h|--help|help) usage; exit 0 ;;
  list) for d in "${APPS[@]}"; do printf '%s\n' "${d##*/}"; done; exit 0 ;;
esac
if [[ ${#APPS[@]} -eq 0 ]]; then note "No apps installed under ${APPS_ROOT} (nothing to manage)."; exit 0; fi

case "$sub" in
  status|ps) run_all ps ;;
  update)    ensure_net; run_all pull; run_all up -d; printf '\n%sUpdate complete.%s Run "archive-apps status" to confirm.\n' "$c_grn" "$c_rst" ;;
  pull)      run_all pull ;;
  up)        ensure_net; run_all up -d ;;
  down)      run_all down ;;
  restart)   run_all restart ;;
  logs)
    app="${1:-}"
    [[ -n "$app" ]] || { err "usage: archive-apps logs <app>   (installed: $(for d in "${APPS[@]}"; do printf '%s ' "${d##*/}"; done))"; exit 2; }
    [[ -d "$APPS_ROOT/$app" && -f "$APPS_ROOT/$app/docker-compose.yml" ]] || { err "no such app: $app"; exit 2; }
    ( cd "$APPS_ROOT/$app" && sudo docker compose logs --tail=200 -f ) ;;
  *) err "unknown action: $sub"; usage; exit 2 ;;
esac
SCRIPT
sudo chmod +x /usr/local/bin/archive-apps

log "Done — app manager installed."
cat <<EOF
    Manage every app from one place (each keeps its own Compose project under ${APPS_ROOT}/<app>):
      archive-apps status        # what's running, across all apps
      archive-apps update        # pull newer images + recreate (the safe way to update them all)
      archive-apps logs immich   # follow one app's logs
      archive-apps restart       # restart everything

    The shared '${DOCKER_NET}' network exists for apps that opt in (newer apps join it automatically);
    Immich/Paperless are unchanged and still reachable on their published ports.
EOF
