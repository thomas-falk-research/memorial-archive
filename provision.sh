#!/usr/bin/env bash
#
# provision.sh — first-boot provisioning for a fresh Ubuntu 26.04 LTS ("resolute") desktop.
#
# Installs (idempotently, re-runnable): base utilities, correct UTF-8 locale, OpenSSH server
# (hardened), Docker Engine + Compose v2 + Buildx, Ansible (pipx), Tailscale, GitHub CLI + git,
# Rust (rustup), Go (official tarball, checksum-verified), Chromium (snap), a security baseline
# (unattended-upgrades + ufw).
#
# Run as a REGULAR user that has sudo. Do NOT run with `sudo ./provision.sh` — the script calls
# sudo itself for the privileged steps and must know your real $HOME for Rust/Go/SSH-key setup.
#
#   chmod +x provision.sh && ./provision.sh
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ----------------------------------------------------------------------------------------------
# Configuration — edit before running if needed.
# ----------------------------------------------------------------------------------------------
LOCALE="en_US.UTF-8"            # locale to generate and set as system LANG
CHARSET="UTF-8"                 # charset for the locale.gen entry
INSTALL_CHROMIUM=true           # Chromium via Canonical snap (the supported desktop path)
ENABLE_FIREWALL=true            # ufw: default-deny inbound, allow SSH + tailnet
ADD_USER_TO_DOCKER_GROUP=true   # let this user run docker without sudo (NOTE: ~= root access)
SSH_DISABLE_PASSWORD_AUTH=false # keep password auth ON by default to avoid locking yourself out;
                                # flip to true ONLY after you've confirmed key-based login works.

# ----------------------------------------------------------------------------------------------
# Helpers and preflight.
# ----------------------------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed."

# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "This script targets Ubuntu; detected ID='${ID:-unknown}'. Proceeding anyway."
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "${CODENAME}" ]] || die "Could not determine Ubuntu codename from /etc/os-release."
[[ "${VERSION_ID:-}" == "26.04" ]] || warn "Expected Ubuntu 26.04; detected '${VERSION_ID:-unknown}' (${CODENAME})."

ARCH="$(dpkg --print-architecture)"   # e.g. amd64
TARGET_USER="$(id -un)"
export DEBIAN_FRONTEND=noninteractive

log "Provisioning Ubuntu ${VERSION_ID:-?} (${CODENAME}/${ARCH}) for user '${TARGET_USER}'"
info "You will be prompted once for your sudo password."
sudo -v   # prime sudo; subsequent calls reuse the cached credential

# ----------------------------------------------------------------------------------------------
# 1. Base packages + locale.
# ----------------------------------------------------------------------------------------------
base_and_locale() {
  log "Updating apt and installing base utilities + locales"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget gnupg lsb-release \
    build-essential pkg-config git \
    jq unzip zip tree rsync tmux htop vim \
    ripgrep fd-find dnsutils net-tools \
    locales

  log "Generating and setting locale ${LOCALE}"
  local line="${LOCALE} ${CHARSET}"
  if ! grep -qxF "${line}" /etc/locale.gen; then
    if grep -qxF "# ${line}" /etc/locale.gen; then
      sudo sed -i "s|^# ${line}\$|${line}|" /etc/locale.gen
    else
      echo "${line}" | sudo tee -a /etc/locale.gen >/dev/null
    fi
  fi
  sudo locale-gen
  sudo update-locale LANG="${LOCALE}" LC_ALL=
  info "LANG set to ${LOCALE} (takes effect in new login sessions)."
}

# Probe an apt repo for a published suite; echo the preferred codename if reachable, else the
# first reachable fallback, else the preferred (so apt surfaces a clear error). Network-tolerant.
resolve_suite() {
  local base="$1" preferred="$2"; shift 2
  local cand
  for cand in "${preferred}" "$@"; do
    if curl -fsSL -o /dev/null --max-time 15 "${base}/dists/${cand}/Release" 2>/dev/null; then
      printf '%s\n' "${cand}"; return 0
    fi
  done
  printf '%s\n' "${preferred}"; return 0
}

# ----------------------------------------------------------------------------------------------
# 2. Third-party APT repositories (deb822 .sources + keyrings under /etc/apt/keyrings).
#    download.docker.com and pkgs.tailscale.com publish per-codename suites; cli.github.com
#    uses a codename-independent 'stable' suite.
# ----------------------------------------------------------------------------------------------
add_apt_repos() {
  log "Configuring Docker, Tailscale, and GitHub CLI apt repositories"
  sudo install -m 0755 -d /etc/apt/keyrings

  # A brand-new Ubuntu release can ship before vendors publish a matching apt suite. Probe for
  # ${CODENAME}; if it 404s, fall back to the newest published LTS so `apt-get update` cannot
  # hard-fail the whole provision. Re-run later to pick up the native suite once it's published.
  local docker_suite tailscale_suite
  docker_suite="$(resolve_suite https://download.docker.com/linux/ubuntu "${CODENAME}" noble jammy)"
  tailscale_suite="$(resolve_suite https://pkgs.tailscale.com/stable/ubuntu "${CODENAME}" noble jammy)"
  [[ "${docker_suite}"    == "${CODENAME}" ]] || warn "Docker has no '${CODENAME}' apt suite yet; using '${docker_suite}'."
  [[ "${tailscale_suite}" == "${CODENAME}" ]] || warn "Tailscale has no '${CODENAME}' apt suite yet; using '${tailscale_suite}'."

  # --- Docker ---
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${docker_suite}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # --- Tailscale --- (key file is per-codename too, so fetch it for the resolved suite)
  if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${tailscale_suite}.noarmor.gpg" \
      | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  fi
  sudo tee /etc/apt/sources.list.d/tailscale.sources >/dev/null <<EOF
Types: deb
URIs: https://pkgs.tailscale.com/stable/ubuntu
Suites: ${tailscale_suite}
Components: main
Architectures: ${ARCH}
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
EOF

  # --- GitHub CLI ---
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  fi
  sudo tee /etc/apt/sources.list.d/github-cli.sources >/dev/null <<EOF
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/githubcli-archive-keyring.gpg
EOF

  log "Refreshing apt with the new repositories"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
}

# ----------------------------------------------------------------------------------------------
# 3. Docker Engine + CLI + containerd + Buildx + Compose v2 plugin.
# ----------------------------------------------------------------------------------------------
install_docker() {
  log "Installing Docker Engine, Buildx, and Compose v2"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker

  if [[ "${ADD_USER_TO_DOCKER_GROUP}" == "true" ]]; then
    if ! id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
      sudo usermod -aG docker "${TARGET_USER}"
      info "Added ${TARGET_USER} to the 'docker' group. Log out and back in for it to take effect."
      info "Until then, use 'sudo docker ...'. (Membership grants root-equivalent access to the host.)"
    fi
  fi
}

# ----------------------------------------------------------------------------------------------
# 4. Tailscale (daemon auto-enables; authenticate later with `sudo tailscale up`).
# ----------------------------------------------------------------------------------------------
install_tailscale() {
  log "Installing Tailscale"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale tailscale-archive-keyring
  sudo systemctl enable --now tailscaled
  info "Authenticate the node when ready:  sudo tailscale up"
}

# ----------------------------------------------------------------------------------------------
# 5. GitHub CLI (git already installed in base step).
# ----------------------------------------------------------------------------------------------
install_gh() {
  log "Installing GitHub CLI"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
  info "Authenticate later with:  gh auth login"
}

# ----------------------------------------------------------------------------------------------
# 6. Ansible via pipx (isolated, current, distro-codename-independent).
# ----------------------------------------------------------------------------------------------
install_ansible() {
  log "Installing Ansible via pipx"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pipx
  pipx ensurepath >/dev/null
  export PATH="${HOME}/.local/bin:${PATH}"
  if pipx list --short 2>/dev/null | grep -qx ansible; then
    pipx upgrade --include-injected ansible >/dev/null || true
  else
    pipx install --include-deps ansible
  fi
  info "ansible / ansible-playbook are in ~/.local/bin (on PATH in new shells)."
}

# ----------------------------------------------------------------------------------------------
# 7. Rust via rustup (per-user; never run rustup as root).
# ----------------------------------------------------------------------------------------------
install_rust() {
  if [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
    log "Rust already present; updating toolchain"
    "${HOME}/.cargo/bin/rustup" update
  else
    log "Installing Rust toolchain (rustup, stable)"
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi
  # shellcheck source=/dev/null
  [[ -f "${HOME}/.cargo/env" ]] && . "${HOME}/.cargo/env"
}

# ----------------------------------------------------------------------------------------------
# 8. Go — official tarball, version resolved at runtime and SHA256-verified, to /usr/local/go.
# ----------------------------------------------------------------------------------------------
install_go() {
  log "Installing Go (official tarball, checksum-verified)"
  local goarch want_ver cur_ver tarball url tmp sum
  case "${ARCH}" in
    amd64) goarch="amd64" ;;
    arm64) goarch="arm64" ;;
    armhf) goarch="armv6l" ;;
    *) warn "No Go tarball mapping for arch '${ARCH}'; skipping Go."; return 0 ;;
  esac

  want_ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"   # e.g. go1.26.4
  [[ "${want_ver}" == go* ]] || die "Could not resolve latest Go version (got '${want_ver}')."

  cur_ver="$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || true)"
  if [[ "${cur_ver}" == "${want_ver}" ]]; then
    info "Go ${want_ver} already installed."
    return 0
  fi

  tarball="${want_ver}.linux-${goarch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  sum="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' \
        | jq -r --arg f "${tarball}" '.[].files[] | select(.filename==$f) | .sha256' | head -n1)"
  [[ -n "${sum}" && "${sum}" != "null" ]] || die "Could not find published SHA256 for ${tarball}."

  tmp="$(mktemp -d)"
  # ${tmp:-}: this RETURN trap also fires when later functions (e.g. main) return, where 'tmp'
  # is out of scope — the :- keeps it from tripping 'set -u' (rm -rf "" is a harmless no-op).
  trap 'rm -rf "${tmp:-}"' RETURN
  curl -fsSL "${url}" -o "${tmp}/${tarball}"
  echo "${sum}  ${tmp}/${tarball}" | sha256sum -c -   # aborts (set -e) if the checksum mismatches

  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "${tmp}/${tarball}"

  sudo tee /etc/profile.d/go.sh >/dev/null <<'EOF'
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
EOF
  info "Installed ${want_ver}. 'go' is on PATH in new login shells."
}

# ----------------------------------------------------------------------------------------------
# 9. Chromium (Canonical snap — the supported path on Ubuntu desktop).
# ----------------------------------------------------------------------------------------------
install_chromium() {
  [[ "${INSTALL_CHROMIUM}" == "true" ]] || { info "Skipping Chromium (disabled in config)."; return 0; }
  log "Installing Chromium (snap)"
  if ! command -v snap >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
  fi
  if snap list chromium >/dev/null 2>&1; then
    info "Chromium snap already installed."
  else
    sudo snap install chromium
  fi
}

# ----------------------------------------------------------------------------------------------
# 10. OpenSSH server + hardening drop-in + per-user ed25519 key.
# ----------------------------------------------------------------------------------------------
configure_ssh() {
  log "Installing and hardening OpenSSH server"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server

  local pwauth="yes"
  [[ "${SSH_DISABLE_PASSWORD_AUTH}" == "true" ]] && pwauth="no"

  sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<EOF
# Managed by provision.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication ${pwauth}
KbdInteractiveAuthentication ${pwauth}
X11Forwarding no
MaxAuthTries 4
EOF

  if sudo sshd -t; then
    sudo systemctl enable ssh >/dev/null 2>&1 || true
    sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart ssh.socket >/dev/null 2>&1 || true
    info "sshd config valid and applied (PermitRootLogin no; PasswordAuthentication ${pwauth})."
  else
    sudo rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    warn "sshd -t rejected the hardening drop-in; reverted it. SSH left at defaults."
  fi

  if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
    install -d -m 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -a 100 -N "" -f "${HOME}/.ssh/id_ed25519" -C "${TARGET_USER}@$(hostname -s)"
    info "Generated ed25519 key (no passphrase). Add one later with: ssh-keygen -p -f ~/.ssh/id_ed25519"
  fi
}

# ----------------------------------------------------------------------------------------------
# 11. Security baseline: automatic security updates + host firewall.
# ----------------------------------------------------------------------------------------------
security_baseline() {
  log "Enabling unattended security upgrades"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
  echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null

  if [[ "${ENABLE_FIREWALL}" == "true" ]]; then
    log "Configuring ufw (deny inbound; allow SSH + tailnet)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow OpenSSH
    sudo ufw allow in on tailscale0
    sudo ufw --force enable
    warn "Docker publishes ports via its own iptables chains and can bypass ufw. Bind sensitive"
    warn "containers to 127.0.0.1 (e.g. -p 127.0.0.1:8080:8080) rather than relying on ufw."
  fi
}

# ----------------------------------------------------------------------------------------------
# 12. Summary.
# ----------------------------------------------------------------------------------------------
summary() {
  log "Installed versions"
  export PATH="${PATH}:/usr/local/go/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/.cargo/bin"
  printf '    %-12s %s\n' "git"      "$(git --version 2>/dev/null || echo 'n/a')"
  printf '    %-12s %s\n' "docker"   "$(docker --version 2>/dev/null || echo 'n/a')"
  printf '    %-12s %s\n' "compose"  "$(docker compose version 2>/dev/null || echo 'n/a')"
  printf '    %-12s %s\n' "ansible"  "$(ansible --version 2>/dev/null | head -n1 || echo 'n/a')"
  printf '    %-12s %s\n' "tailscale" "$(tailscale version 2>/dev/null | head -n1 || echo 'n/a')"
  printf '    %-12s %s\n' "gh"       "$(gh --version 2>/dev/null | head -n1 || echo 'n/a')"
  printf '    %-12s %s\n' "rustc"    "$(rustc --version 2>/dev/null || echo 'n/a')"
  printf '    %-12s %s\n' "go"       "$(go version 2>/dev/null || echo 'n/a')"
  printf '    %-12s %s\n' "chromium" "$(snap list chromium 2>/dev/null | awk 'NR==2{print $2}' || echo 'n/a')"

  log "Next steps"
  cat <<EOF
    1. Log out and back in (or reboot) to pick up: docker group, Go/Rust/pipx PATH, new LANG.
    2. Authenticate Tailscale:   sudo tailscale up
    3. Authenticate GitHub CLI:  gh auth login
    4. Your SSH public key:      ~/.ssh/id_ed25519.pub
    5. SSH is currently $( [[ "${SSH_DISABLE_PASSWORD_AUTH}" == "true" ]] && echo "key-only" || echo "password+key" ).
       To go key-only after confirming key login: set PasswordAuthentication no in
       /etc/ssh/sshd_config.d/99-hardening.conf, then 'sudo systemctl restart ssh'.
EOF
}

# ----------------------------------------------------------------------------------------------
main() {
  base_and_locale
  add_apt_repos
  install_docker
  install_tailscale
  install_gh
  install_ansible
  install_rust
  install_go
  install_chromium
  configure_ssh
  security_baseline
  summary
  log "Done."
}
main "$@"
