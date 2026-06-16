#!/usr/bin/env bash
#
# archive-webui-setup.sh — Phase 5: let the family keyword-SEARCH the archive from a phone browser.
#
# Stands up the recoll web UI behind an authenticated Caddy reverse proxy on the LOCAL NETWORK
# (and your tailnet). The family opens http://<this-machine>.local:PORT in Safari, signs in, and
# searches the whole archive (file contents + names). The web UI itself listens only on loopback;
# Caddy adds the password and exposes it. Read-only — it can only search and download.
#
# Requires archive-search-setup.sh + 'archive-index' first (it serves that recoll index).
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-webui-setup.sh`).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
WEBUI_DIR="${WEBUI_DIR:-/opt/recoll-webui}"
WEBUI_REPO="${WEBUI_REPO:-https://framagit.org/medoc92/recollwebui.git}"
WEBUI_PIN="${WEBUI_PIN:-127f849ae4bb4a690908ffef62cfb2d43784862d}"   # pinned, reviewed commit
WEBUI_PORT="${WEBUI_PORT:-8080}"                     # public port Caddy listens on (the family's URL)
WEBUI_INTERNAL_PORT="${WEBUI_INTERNAL_PORT:-8088}"   # loopback port the web UI binds
WEBUI_USER="${WEBUI_USER:-family}"                   # the web sign-in name
CADDYFILE="/etc/caddy/Caddyfile"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip prompts; generate a random web password and print it
  --help, -h  show this help and exit
Env overrides: WEBUI_PORT (default 8080), WEBUI_USER (default 'family'), WEBUI_DIR, WEBUI_PIN.
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
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null || true
[[ "${ID:-}" == "ubuntu" ]] || warn "Targeting Ubuntu; detected ID='${ID:-unknown}'."
export DEBIAN_FRONTEND=noninteractive

ARCHIVE_ROOT="/srv/archive"
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"

# Run the web UI as the archive owner so it can read every indexed file (fallback: this user).
SVC_USER="$(stat -c %U "$ARCHIVE_ROOT" 2>/dev/null || true)"
SVC_GROUP="$(stat -c %G "$ARCHIVE_ROOT" 2>/dev/null || true)"
if [[ -z "$SVC_USER" || "$SVC_USER" == "root" ]]; then SVC_USER="$(id -un)"; SVC_GROUP="$(id -gn)"; fi

[[ -d "$RECOLL_CONFDIR" ]] || warn "No recoll index at ${RECOLL_CONFDIR} yet. Run archive-search-setup.sh and 'archive-index' first (the web UI will find nothing until then)."

log "This will set up the family search web UI, using sudo:"
printf '    - install: git python3-recoll python3-waitress caddy\n'
printf '    - web UI : %s (pinned %s), run as %s on 127.0.0.1:%s\n' "$WEBUI_DIR" "${WEBUI_PIN:0:12}" "$SVC_USER" "$WEBUI_INTERNAL_PORT"
printf '    - caddy  : password-protected proxy on port %s (local network + tailnet)\n' "$WEBUI_PORT"
printf '    - sign-in: %s  (you set its password below)\n' "$WEBUI_USER"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi
sudo -v

log "Installing packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git python3-recoll python3-waitress caddy

log "Fetching the recoll web UI (${WEBUI_REPO})"
if [[ -d "${WEBUI_DIR}/.git" ]]; then
  sudo git -C "$WEBUI_DIR" fetch -q origin || warn "fetch failed; using existing checkout"
else
  sudo git clone -q "$WEBUI_REPO" "$WEBUI_DIR" || die "Could not clone the recoll web UI from ${WEBUI_REPO}"
fi
sudo git -C "$WEBUI_DIR" checkout -q "$WEBUI_PIN" 2>/dev/null || warn "Could not pin to ${WEBUI_PIN}; using the current checkout."

log "Installing the launcher to /usr/local/bin"
sudo tee /usr/local/bin/archive-webui-run >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-webui-run — launch the recoll web UI on loopback. nginx (with a password) publishes it
# to the local network. Started by the archive-webui systemd service; not normally run by hand.
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"
WEBUI_DIR="${WEBUI_DIR:-/opt/recoll-webui}"
WEBUI_INTERNAL_PORT="${WEBUI_INTERNAL_PORT:-8088}"
export RECOLL_CONFDIR

[[ -d "$WEBUI_DIR" ]] || { echo "archive-webui-run: web UI not found at $WEBUI_DIR" >&2; exit 1; }
cd "$WEBUI_DIR" || exit 1
echo "archive-webui-run: recoll web UI on 127.0.0.1:${WEBUI_INTERNAL_PORT} (index: ${RECOLL_CONFDIR})"
exec python3 ./webui-standalone.py -a 127.0.0.1 -p "$WEBUI_INTERNAL_PORT" -c "$RECOLL_CONFDIR"
SCRIPT
sudo chmod +x /usr/local/bin/archive-webui-run

log "Installing the systemd service (hardened; web UI bound to loopback)"
sudo tee /etc/systemd/system/archive-webui.service >/dev/null <<UNIT
[Unit]
Description=Recoll web UI for the digital archive (read-only family search)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=${SVC_USER}
Group=${SVC_GROUP}
Environment=HOME=/tmp
Environment=WEBUI_DIR=${WEBUI_DIR}
Environment=WEBUI_INTERNAL_PORT=${WEBUI_INTERNAL_PORT}
ExecStart=/usr/local/bin/archive-webui-run
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=tmpfs
ReadOnlyPaths=${ARCHIVE_ROOT} ${WEBUI_DIR}
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now archive-webui >/dev/null 2>&1 || true

log "Configuring Caddy (password-protected reverse proxy)"
if sudo test -f "$CADDYFILE" && sudo grep -q 'archive-webui managed' "$CADDYFILE" 2>/dev/null; then
  GEN_PW=""
  info "Caddy already configured for the archive — leaving the password/port unchanged."
  info "To change the password: sudo caddy hash-password ; edit ${CADDYFILE} ; sudo systemctl reload caddy"
else
  GEN_PW=""
  if [[ "${ASSUME_YES}" == "true" ]]; then
    GEN_PW="$(openssl rand -base64 12 2>/dev/null || head -c 9 /dev/urandom | base64)"; pw="$GEN_PW"
  else
    read -rsp "Set a password for the web search login '${WEBUI_USER}': " pw; echo
    read -rsp "Confirm: " pw2; echo
    [[ -n "$pw" ]] || die "Password cannot be empty."
    [[ "$pw" == "$pw2" ]] || die "Passwords did not match."
  fi
  HASH="$(caddy hash-password --plaintext "$pw" 2>/dev/null)" || die "caddy hash-password failed."
  unset pw pw2

  # Caddy renamed 'basicauth' (<2.8) to 'basic_auth' (>=2.8). Detect which this build accepts.
  auth_dir="basic_auth"
  probe="$(mktemp)"
  printf ':%s {\n  %s {\n    %s %s\n  }\n  reverse_proxy 127.0.0.1:%s\n}\n' \
    "$WEBUI_PORT" "$auth_dir" "$WEBUI_USER" "$HASH" "$WEBUI_INTERNAL_PORT" > "$probe"
  caddy validate --adapter caddyfile --config "$probe" >/dev/null 2>&1 || auth_dir="basicauth"
  rm -f "$probe"

  [[ -f "${CADDYFILE}.orig" ]] || sudo cp -a "$CADDYFILE" "${CADDYFILE}.orig" 2>/dev/null || true
  # printf %s writes the bcrypt hash literally ($-signs are data, not expanded).
  printf '# archive-webui managed by archive-webui-setup.sh\n:%s {\n  %s {\n    %s %s\n  }\n  reverse_proxy 127.0.0.1:%s\n}\n' \
    "$WEBUI_PORT" "$auth_dir" "$WEBUI_USER" "$HASH" "$WEBUI_INTERNAL_PORT" | sudo tee "$CADDYFILE" >/dev/null

  if sudo caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    sudo systemctl enable --now caddy >/dev/null 2>&1 || true
    sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
    info "Caddy configured and reloaded (auth directive: ${auth_dir})."
  else
    [[ -f "${CADDYFILE}.orig" ]] && sudo cp -a "${CADDYFILE}.orig" "$CADDYFILE"
    die "Caddy config invalid — reverted. The web UI runs on loopback; fix Caddy and re-run."
  fi
fi

# Open the public port through ufw (if active) for the local network. Router/NAT blocks the internet.
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow "${WEBUI_PORT}/tcp" >/dev/null 2>&1 || true
  info "allowed web UI port ${WEBUI_PORT} through ufw for the local network."
fi

host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ts_name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
log "Done — the family can search the archive from a phone browser."
cat <<EOF
    On any phone/tablet on the home Wi-Fi, open Safari/Chrome to:
        http://${host_short}.local:${WEBUI_PORT}/        (or  http://${lan_ip:-<LAN-IP>}:${WEBUI_PORT}/ )
      Sign in:  ${WEBUI_USER} / $( [[ -n "${GEN_PW:-}" ]] && echo "${GEN_PW}   (save this now)" || echo "the password you set" )
      Type keywords, tap a result to open or download the file.

    Notes:
      - The web UI is READ-ONLY and password-protected; it searches file contents AND names.
      - It is on the local network, not the public internet. You can also reach it over your
        tailnet at:  http://${ts_name:-<your-tailscale-name>}:${WEBUI_PORT}/
      - After new ingests, run 'archive-index' so results stay current (the web UI updates live).
      - Change the password: sudo caddy hash-password ; edit ${CADDYFILE} ; sudo systemctl reload caddy
EOF
[[ -n "${GEN_PW:-}" ]] && warn "The generated password above is shown only once. Save it now."
