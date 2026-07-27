#!/usr/bin/env bash
#
# archive-paperless-setup.sh — document manager (Paperless-ngx) for the family.
#
# Deploys Paperless-ngx as a PINNED Docker Compose stack (Postgres + Redis + the app). It OCRs,
# tags, and full-text-indexes documents you place in its consume folder, with a friendly web UI.
# App data lives on the OS disk (Docker-managed volumes, off the 2 TB archive budget); the consume/
# export folders are under /srv/apps/paperless so you can drop files in. Reachable on the local
# network (and tailnet) at :8000.
#
# VERSION SAFETY — this script does NOT float to "latest" on an existing install. Paperless-ngx v3
# is a one-way migration (it can only be entered from v2.20.15, it drops task history, it removes
# document encryption, and its compose has moved the Postgres image + the pgdata mount path). An
# unattended jump can leave the app running against a freshly-initialised, EMPTY database while the
# document files sit untouched in the media volume — a silent, total-looking loss of tags/titles.
# So:
#   * a FRESH install gets the recorded pin below (never "whatever is latest today");
#   * a RE-RUN keeps the tag that is already deployed (zero drift);
#   * --upgrade advances to the latest release, but a MAJOR version change additionally needs
#     --upgrade-major AND an existing document_exporter export;
#   * the new compose is fetched to a temp file and compared with the live one first — if the db
#     image or the pgdata mount path would change, the script REFUSES and touches nothing.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${PAPERLESS_DIR:-/srv/apps/paperless}"
PAPERLESS_VERSION="${PAPERLESS_VERSION:-}"     # empty = keep what's installed (pinned default on a fresh box)
PAPERLESS_PORT=8000                            # fixed: Paperless's compose publishes 8000 (the proxy + .home names front it)
PAPERLESS_ADMIN_USER="${PAPERLESS_ADMIN_USER:-admin}"
OCR_LANGUAGE="${OCR_LANGUAGE:-eng}"
# The recorded pin: what a FRESH install deploys, and the fallback if a --upgrade lookup fails.
# Audited by ci/version-audit.sh — bump it deliberately, never automatically.
FALLBACK_VERSION="v3.0.3"

ASSUME_YES=false
ALLOW_UPGRADE=false
ALLOW_MAJOR=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--upgrade] [--upgrade-major] [--help|-h]
  --yes, -y        skip prompts; generate a random admin password and print it
  --upgrade        advance an existing install to the latest upstream release
                   (without it, a re-run keeps the tag already deployed)
  --upgrade-major  additionally allow crossing a MAJOR version (e.g. 2.x -> 3.x) or changing the
                   database image / pgdata mount. Requires an existing export in APP_DIR/export.
                   Read docs/PAPERLESS-DOCUMENT-VIEW.md before you use this.
  --help, -h       show this help and exit
Env overrides: PAPERLESS_VERSION (deploy an exact tag), PAPERLESS_ADMIN_USER (default
'admin'), OCR_LANGUAGE (default 'eng'), PAPERLESS_DIR.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    --upgrade|--latest) ALLOW_UPGRADE=true ;;
    --upgrade-major) ALLOW_UPGRADE=true; ALLOW_MAJOR=true ;;
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

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# ---- Version resolution ----------------------------------------------------------------------
# What is deployed RIGHT NOW (our override file pins the app image, so it is the source of truth).
installed_tag=""
if sudo test -f "$APP_DIR/docker-compose.override.yml"; then
  installed_tag="$(sudo sed -n 's#.*paperless-ngx:##p' "$APP_DIR/docker-compose.override.yml" 2>/dev/null \
    | head -1 | tr -d '[:space:]')"
fi

version_source=""
if [[ -n "$PAPERLESS_VERSION" ]]; then
  version_source="requested explicitly"
elif [[ "$ALLOW_UPGRADE" == true ]]; then
  info "Resolving the latest Paperless-ngx release..."
  PAPERLESS_VERSION="$(git ls-remote --tags --refs https://github.com/paperless-ngx/paperless-ngx 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  version_source="latest upstream"
  [[ -n "$PAPERLESS_VERSION" ]] || { PAPERLESS_VERSION="$FALLBACK_VERSION"; version_source="pinned fallback"; warn "Release lookup failed; using ${PAPERLESS_VERSION}."; }
elif [[ -n "$installed_tag" ]]; then
  # A re-run must NOT move the version. Advancing needs --upgrade, deliberately.
  PAPERLESS_VERSION="$installed_tag"; version_source="already installed (no drift; use --upgrade to advance)"
else
  PAPERLESS_VERSION="$FALLBACK_VERSION"; version_source="pinned default for a fresh install"
fi
# Git release tags are vX.Y.Z, but the container image tag drops the leading 'v' (e.g. 2.20.15).
# Keep the git ref (with 'v') for the compose/env downloads; use the image tag (no 'v') for the pin.
PAPERLESS_VERSION="v${PAPERLESS_VERSION#v}"
IMAGE_TAG="${PAPERLESS_VERSION#v}"

# ---- Version-change guard ----------------------------------------------------------------------
# Paperless-ngx v3 is a one-way door (see the header). Refuse to cross a major boundary — or to move
# BACKWARDS onto a database that has already migrated forwards — unless the operator says so and has
# an export to fall back on.
major_of() { local v="${1#v}"; printf '%s' "${v%%.*}"; }
if [[ -n "$installed_tag" && "${installed_tag#v}" != "$IMAGE_TAG" ]]; then
  cur_major="$(major_of "$installed_tag")"; new_major="$(major_of "$IMAGE_TAG")"
  older="$(printf '%s\n%s\n' "${installed_tag#v}" "$IMAGE_TAG" | sort -V | head -1)"
  crossing=""
  [[ "$cur_major" != "$new_major" ]] && crossing="major version change ${cur_major}.x -> ${new_major}.x"
  [[ -z "$crossing" && "$older" == "$IMAGE_TAG" ]] && crossing="DOWNGRADE ${installed_tag#v} -> ${IMAGE_TAG} (the database has already migrated forwards)"
  if [[ -n "$crossing" ]]; then
    if [[ "$ALLOW_MAJOR" != true ]]; then
      die "Refusing: ${crossing}.
    Installed: ${installed_tag#v}   ·   would deploy: ${IMAGE_TAG} (${version_source})
    This is NOT a routine update. Paperless-ngx v3 can only be entered from v2.20.15 (after its
    migrations have run), it drops all task history, and it removes document encryption (run
    decrypt_documents FIRST if you ever enabled a passphrase). v3.0.1 also shipped a broken
    migration — never land on it.
    Read docs/PAPERLESS-DOCUMENT-VIEW.md, take an export, then re-run with --upgrade-major.
    Nothing was changed."
    fi
    sudo test -s "$APP_DIR/export/manifest.json" || die "Refusing: ${crossing} with no export to fall back on.
    Take one first (it is the only way back if the migration goes wrong):
        cd ${APP_DIR} && sudo docker compose exec -T webserver document_exporter ../export
    then re-run with --upgrade-major. Nothing was changed."
    warn "${crossing} — allowed by --upgrade-major, with an export present in ${APP_DIR}/export."
  fi
fi

host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')"
uid="$(id -u)"; gid="$(id -g)"

# Detect a prior install: a re-run must NOT rotate the admin password, regenerate the secret, or
# wipe your docker-compose.env edits (e.g. PAPERLESS_URL). On re-run we refresh only the compose
# file and the version pin, and leave your env file untouched.
first_install=true
if sudo test -f "$APP_DIR/docker-compose.env" && sudo grep -q 'archive-paperless-setup.sh' "$APP_DIR/docker-compose.env" 2>/dev/null; then
  first_install=false
fi

log "This will deploy Paperless-ngx ${PAPERLESS_VERSION} with Docker, using sudo:"
printf '    - version: %s  (%s)\n' "$PAPERLESS_VERSION" "$version_source"
printf '    - app + database + redis (Docker-managed volumes on the OS disk, off the archive budget)\n'
printf '    - drop documents to OCR/index into:  %s/consume\n' "$APP_DIR"
printf '    - reachable on the local network + tailnet at port %s\n' "$PAPERLESS_PORT"
if [[ "$first_install" == true ]]; then printf '    - admin login: %s  (you set its password below)\n' "$PAPERLESS_ADMIN_USER"
else printf '    - re-run: keeping your settings (admin password, PAPERLESS_URL); refreshing to %s\n' "$PAPERLESS_VERSION"; fi
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

# Admin password (terminal only — never echoed; never paste it in chat).
GEN_PW=""
if [[ "$first_install" == true ]]; then
  if [[ "${ASSUME_YES}" == "true" ]]; then
    GEN_PW="$(openssl rand -base64 12 2>/dev/null || head -c 9 /dev/urandom | base64)"; admin_pw="$GEN_PW"
  else
    read -rsp "Set a password for the Paperless '${PAPERLESS_ADMIN_USER}' login: " admin_pw; echo
    read -rsp "Confirm: " admin_pw2; echo
    [[ -n "$admin_pw" ]] || die "Password cannot be empty."
    [[ "$admin_pw" == "$admin_pw2" ]] || die "Passwords did not match."
  fi
fi

log "Creating ${APP_DIR} (with consume/ and export/)"
sudo mkdir -p "$APP_DIR/consume" "$APP_DIR/export"
sudo chown "$uid:$gid" "$APP_DIR/consume" "$APP_DIR/export"

log "Fetching Paperless-ngx official compose (pinned ${PAPERLESS_VERSION})"
# Fetch to a TEMP file and vet it BEFORE it replaces the live compose. Writing straight over
# docker-compose.yml would leave a half-applied config behind if any check below refuses.
new_compose="$(mktemp)"; live_compose="$(mktemp)"
trap 'rm -f "$new_compose" "$live_compose"' EXIT
curl -fsSL "https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/${PAPERLESS_VERSION}/docker/compose/docker-compose.postgres.yml" \
  -o "$new_compose" || die "Could not download Paperless's compose for ${PAPERLESS_VERSION}. Nothing was changed."
[[ -s "$new_compose" ]] || die "Downloaded compose for ${PAPERLESS_VERSION} is empty. Nothing was changed."

# The stateful bits: which Postgres image runs, and where its data directory is mounted. Upstream has
# moved BOTH across recent tags (postgres:16 at /var/lib/postgresql/data -> postgres:18 at
# /var/lib/postgresql). Silently applying either change points Postgres at an empty PGDATA inside the
# same volume, so it initialises a BLANK cluster and Paperless comes up with no documents, no tags and
# no correspondents — while the files sit untouched in the media volume. Never let that happen quietly.
compose_db_image() {   # first `image:` under the top-level `db:` service
  awk '/^[[:space:]]{2}db:[[:space:]]*$/{inblk=1;next}
       inblk && /^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/{inblk=0}
       inblk && $1=="image:"{print $2; exit}' "$1"
}
compose_pgdata_mount() { grep -oE 'pgdata:/[^"'"'"'[:space:]]*' "$1" | head -1; }

if [[ -n "$installed_tag" ]] && sudo test -f "$APP_DIR/docker-compose.yml"; then
  # SC2024 (sudo doesn't affect redirects) is exactly what we want: sudo is only needed to READ the
  # root-owned compose, and $live_compose is our own mktemp file, so the redirect must stay unprivileged.
  # shellcheck disable=SC2024
  sudo cat "$APP_DIR/docker-compose.yml" >"$live_compose" 2>/dev/null || : >"$live_compose"
  old_db="$(compose_db_image "$live_compose")";     new_db="$(compose_db_image "$new_compose")"
  old_pg="$(compose_pgdata_mount "$live_compose")"; new_pg="$(compose_pgdata_mount "$new_compose")"
  if [[ -n "$old_db" && -n "$new_db" && "$old_db" != "$new_db" ]] || \
     [[ -n "$old_pg" && -n "$new_pg" && "$old_pg" != "$new_pg" ]]; then
    if [[ "$ALLOW_MAJOR" != true ]]; then
      die "Refusing: the ${PAPERLESS_VERSION} compose changes the DATABASE layout.
      database image: ${old_db:-?}  ->  ${new_db:-?}
      pgdata mount:   ${old_pg:-?}  ->  ${new_pg:-?}
    Applying this as-is can initialise an EMPTY Postgres cluster in the existing volume: Paperless
    would start up with no documents, tags or correspondents, and it would look like total loss.
    A major-version Postgres change also needs a dump/restore — the new image will not read the old
    data directory. Take an export, read docs/PAPERLESS-DOCUMENT-VIEW.md, and only then re-run with
    --upgrade-major. Nothing was changed."
    fi
    warn "Database layout change accepted via --upgrade-major (${old_db:-?} -> ${new_db:-?}, ${old_pg:-?} -> ${new_pg:-?})."
    warn "If Paperless comes up EMPTY, STOP and restore from the export — do not consume anything into it."
  fi
  # Keep the outgoing compose so a bad update can be rolled straight back.
  sudo cp -a "$APP_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml.bak-${installed_tag#v}" 2>/dev/null \
    && info "kept the previous compose as docker-compose.yml.bak-${installed_tag#v}"
fi

sudo cp "$new_compose" "$APP_DIR/docker-compose.yml"
sudo chmod 0644 "$APP_DIR/docker-compose.yml"
if [[ "$first_install" == false ]]; then
  info "Existing install — keeping your docker-compose.env (admin password, PAPERLESS_URL, secret preserved)."
else
  sudo curl -fsSL "https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/${PAPERLESS_VERSION}/docker/compose/docker-compose.env" \
    -o "$APP_DIR/docker-compose.env" || die "Could not download Paperless's env template."
fi

if [[ "$first_install" == true ]]; then
log "Writing settings (.env additions, pinned image, generated secret)"
if [[ -f "$APP_DIR/.paperless-secret" ]] && sudo test -s "$APP_DIR/.paperless-secret"; then
  secret="$(sudo cat "$APP_DIR/.paperless-secret")"
else
  secret="$(openssl rand -hex 32 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 50)"
  printf '%s' "$secret" | sudo tee "$APP_DIR/.paperless-secret" >/dev/null && sudo chmod 600 "$APP_DIR/.paperless-secret"
fi
# Append our settings to the env file (later values win over the commented defaults above).
sudo tee -a "$APP_DIR/docker-compose.env" >/dev/null <<EOF

# ---- Added by archive-paperless-setup.sh ----
USERMAP_UID=${uid}
USERMAP_GID=${gid}
PAPERLESS_TIME_ZONE=${tz}
PAPERLESS_OCR_LANGUAGE=${OCR_LANGUAGE}
PAPERLESS_URL=http://${host_short}.local:${PAPERLESS_PORT}
PAPERLESS_SECRET_KEY=${secret}
PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER}
PAPERLESS_ADMIN_PASSWORD=${admin_pw}
EOF
sudo chmod 600 "$APP_DIR/docker-compose.env"
unset admin_pw admin_pw2 2>/dev/null || true
fi
# Pin the app image (upstream ships :latest) and map the chosen port.
sudo tee "$APP_DIR/docker-compose.override.yml" >/dev/null <<EOF
# Managed by archive-paperless-setup.sh — pin the image and the published port.
services:
  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:${IMAGE_TAG}
    ports:
      - "${PAPERLESS_PORT}:8000"
EOF

log "Validating the merged compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow "${PAPERLESS_PORT}/tcp" >/dev/null 2>&1 || true
  info "opened port ${PAPERLESS_PORT} in ufw for the local network."
fi

log "Starting Paperless-ngx (first run pulls images + initialises the database — a few minutes)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — Paperless-ngx is starting."
if [[ -n "$GEN_PW" ]]; then signin="${GEN_PW}   (save this now)"
elif [[ "$first_install" == true ]]; then signin="the password you just set"
else signin="your existing admin password (unchanged)"; fi
cat <<EOF
    Open it (give it a couple of minutes on first start while it migrates the DB):
        http://${host_short}.local:${PAPERLESS_PORT}/     (or  http://${lan_ip:-<LAN-IP>}:${PAPERLESS_PORT}/ )
      Sign in:  ${PAPERLESS_ADMIN_USER} / ${signin}

    To file documents: copy PDFs/scans/images into
        ${APP_DIR}/consume
      Paperless watches that folder, OCRs + tags each file, and adds it to the searchable library.
      (recoll still searches the whole archive as-is; Paperless is the curated, OCR'd documents view.)

    Notes:
      - App data + the database are Docker-managed volumes on the OS disk (off the archive budget).
        'archive-backup' backs them up automatically — Paperless's own exporter (documents + tags)
        into /srv/backup/apps/paperless, with a RESTORE.txt alongside.
      - If you reach it by IP/Tailscale and hit a login/CSRF error, set PAPERLESS_URL in
        ${APP_DIR}/docker-compose.env to that address and 'sudo docker compose up -d'.
      - Manage:  cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Add more family logins in the web UI under the admin (gear) -> Users & Groups.
EOF
# NOT `[[ -n "$GEN_PW" ]] && warn ...` — as the last command of the script that makes a successful
# RE-RUN (where no password was generated) exit 1, which reads as a failed update to every caller.
if [[ -n "$GEN_PW" ]]; then
  warn "The generated password above is shown only once. Save it now."
fi
exit 0
