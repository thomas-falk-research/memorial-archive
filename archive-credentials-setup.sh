#!/usr/bin/env bash
#
# archive-credentials-setup.sh — install 'archive-credentials', the family's SINGLE reference for
# every login on the box: where each secret lives and how to RESET it.
#
# The installed command is deliberately a *guide*, not a vault: it never displays the actual
# passwords (so it can't leak them and nothing sensitive lands in terminal scrollback or logs), and
# it needs no sudo to run — it only inspects which components are present and prints instructions.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-credentials-setup.sh`).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  Installs /usr/local/bin/archive-credentials — a read-only guide to every login on the box
  and how to reset each one. It never shows the actual passwords.
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
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

[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required (to install into /usr/local/bin)."

log "This will install the 'archive-credentials' command (a read-only password & reset guide):"
printf '    - lists every login on the box and HOW TO RESET it (it never shows the real passwords)\n'
printf '    - installed to /usr/local/bin/archive-credentials; run it anytime, no sudo needed\n'
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Installing /usr/local/bin/archive-credentials"
sudo tee /usr/local/bin/archive-credentials >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-credentials — your single reference for every login on this machine: where each secret
# lives and how to RESET it. For safety it NEVER prints the actual passwords; it only shows where
# things are and the exact steps to set a new one. Read-only and needs no sudo to run.
set -uo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'USAGE'
Usage: archive-credentials
  Prints, for each login on this box, where its secret lives and how to RESET it.
  It does NOT display any actual password. Safe to run anytime; needs no sudo.
USAGE
    exit 0 ;;
  "") : ;;
  *) printf 'archive-credentials: unknown argument %q (try --help)\n' "$1" >&2; exit 2 ;;
esac

# Pick up APPS_ROOT / BASE_DOMAIN if the box has them configured (purely for accurate paths/URLs).
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
APPS_ROOT="${APPS_ROOT:-/srv/apps}"
BASE_DOMAIN="${BASE_DOMAIN:-home}"
RESTIC_PASS_FILE="${RESTIC_PASSWORD_FILE:-/etc/archive-restic.pass}"

if [[ -t 1 ]]; then b=$'\033[1m'; cyn=$'\033[1;36m'; rst=$'\033[0m'; else b=""; cyn=""; rst=""; fi
h() { printf '\n%s%s%s\n' "$cyn" "$1" "$rst"; }

# The SMB share records its login as 'valid users' in smb.conf (world-readable); default 'family'.
smb_user="$(awk -F= 'tolower($0) ~ /valid +users/ {gsub(/[ \t]/,"",$2); print $2; exit}' /etc/samba/smb.conf 2>/dev/null)"
[[ -n "$smb_user" ]] || smb_user="family"

printf '%s\n' "${b}Memorial Archive — passwords & logins${rst}"
cat <<'TXT'
=====================================================================================
Your single place for every login on the box: where each one lives and how to RESET it.
For safety this NEVER shows the actual passwords — to get back in, follow the reset steps.
Run the steps below ON THE BOX (a terminal / SSH). Lines that start with 'sudo' will ask
for the computer's administrator password.
TXT

# --- the machine itself (always relevant) -----------------------------------------------------
h "The mini-PC itself  —  the administrator ('sudo') password"
cat <<'TXT'
  This is what you type for 'sudo' and to log in to the computer.
    Change YOUR OWN:      passwd
    Change another user:  sudo passwd <username>
  Change it now if it was ever typed somewhere it might have been seen.
TXT

# --- family sign-in (Caddy basic-auth) — present once a front door / web search exists --------
if [[ -e /etc/caddy/Caddyfile ]]; then
  h "Family sign-in  —  one shared password for Search / Files / Duplicates / PDF tools"
  cat <<TXT
  Used at:   search.${BASE_DOMAIN}, files.${BASE_DOMAIN}, dupes.${BASE_DOMAIN}, pdf.${BASE_DOMAIN}
  Username:  family
  Stored as: a one-way scramble in /etc/caddy/Caddyfile (the real password is never saved).
  Reset it:
    - Easiest — in the memorial-archive folder, re-run the front door and set a new one:
        RESET_SEARCH_PW=1 ./archive-proxy-setup.sh
    - By hand:  sudo caddy hash-password   (type the new password; copy the printed line),
      replace the long scrambled value after 'family' in /etc/caddy/Caddyfile, then:
        sudo systemctl reload caddy
TXT
fi

# --- Immich -----------------------------------------------------------------------------------
if [[ -d "$APPS_ROOT/immich" ]]; then
  h "Photos & videos (Immich)  —  http://photos.${BASE_DOMAIN}/   (or port 2283)"
  cat <<TXT
  Everyone has their OWN account; the FIRST account created is the administrator.
  Its internal database password lives in ${APPS_ROOT}/immich/.env (apps-only — you never type it).
  Reset a family member:  the admin opens  Administration -> Users  and resets them.
  Locked out of the ADMIN account itself (check https://immich.app/docs for your version):
      cd ${APPS_ROOT}/immich && sudo docker compose exec immich_server immich-admin reset-admin-password
TXT
fi

# --- Paperless --------------------------------------------------------------------------------
if [[ -d "$APPS_ROOT/paperless" ]]; then
  h "Documents (Paperless-ngx)  —  http://docs.${BASE_DOMAIN}/   (or port 8000)"
  cat <<TXT
  Username:  admin   (add more people under the gear -> Users & Groups)
  Secret file: ${APPS_ROOT}/paperless/docker-compose.env  (admin password + secret key — keep it).
  Reset a password (run on the box):
      cd ${APPS_ROOT}/paperless && sudo docker compose exec webserver python manage.py changepassword admin
  (Editing the password in docker-compose.env does NOT change an existing login — use the command.)
TXT
fi

# --- Docmost ----------------------------------------------------------------------------------
if [[ -d "$APPS_ROOT/docmost" ]]; then
  h "Notes & memories (Docmost)  —  http://docmost.${BASE_DOMAIN}/   (or port 3000)"
  cat <<TXT
  Everyone has their OWN account; the FIRST account created is the workspace owner.
  Secret file: ${APPS_ROOT}/docmost/.env  (app secret + database password — keep it).
  Reset a member:  an owner/admin opens  Settings -> Members  and resets them.
  Tip: create a SECOND owner account as a spare — password-reset emails need a mail server,
       which isn't set up by default. Docs: https://docmost.com/docs
TXT
fi

# --- read-only SMB share (iPhone/iPad Files app) ----------------------------------------------
if grep -qs 'Digital Archive' /etc/samba/smb.conf 2>/dev/null; then
  h "Files on iPhone/iPad (the SMB share)  —  Files app -> Connect to Server"
  cat <<TXT
  Username:  ${smb_user}
  Reset it:  sudo smbpasswd ${smb_user}
TXT
fi

# --- backup share login -----------------------------------------------------------------------
if [[ -e /etc/archive-backup.cred ]]; then
  h "Backup share login  —  only if your backup goes to a network share"
  cat <<'TXT'
  Stored in: /etc/archive-backup.cred  (administrator-only).
  Reset it:  re-enter the share's username/password with:  archive-storage attach-backup
TXT
fi

# --- restic backup passphrase (the one secret that cannot be reset) ---------------------------
if [[ -e "$RESTIC_PASS_FILE" ]]; then
  h "Backup encryption passphrase (Restic)  —  the ONE secret you cannot reset"
  cat <<TXT
  It encrypts your off-site snapshots and is stored (mode 600) at:
      ${RESTIC_PASS_FILE}
  There is NO reset: if this is lost, the encrypted backup can never be opened again. So:
    - Keep a copy OFF the box — a password manager, or written down somewhere safe.
    - To read it (to record it):  cat ${RESTIC_PASS_FILE}
  (Changing it would orphan every existing snapshot, so the tools never rotate it.)
TXT
fi

# --- Windows-PC backup server (Kopia) ---------------------------------------------------------
if [[ -d "$APPS_ROOT/kopia" ]]; then
  h "Windows-PC backup server (Kopia)  —  the family's PCs back up to the box"
  cat <<TXT
  Each PC has its OWN login (username = its name). Manage them on the box:
      archive-pc-backup add <pc-name>      create a PC's login (prints its password + the
                                           server URL and certificate fingerprint for KopiaUI)
      archive-pc-backup list               see which PCs are set up
      archive-pc-backup remove <pc-name>   revoke a PC
      archive-pc-backup info               show the URL + fingerprint again
  To RESET a PC's password: 'remove' then 'add' it again (KopiaUI re-enters the new one).
  Repository password: ${APPS_ROOT}/kopia/.env (mode 600). Like the restic passphrase it CANNOT be
  reset — losing it makes the PC backups in /srv/pc-backups unreadable. Record it off the box.
TXT
fi

# --- good habits ------------------------------------------------------------------------------
h "Good habits"
cat <<'TXT'
  - Keep the 'secret file' paths above safe — they're tiny but let you rebuild a working app.
    (Your verified backup already copies each app's DATA; these files complete the picture.)
  - Logins that are NOT on this box — your router, AdGuard, your Tailscale account — aren't
    managed here; reset those in those tools.
  - Lost an account entirely? Re-create the app with  ./manage.sh -> Install  and restore from
    the backup (see the RESTORE.txt files under /srv/backup/apps).
TXT
SCRIPT
sudo chmod +x /usr/local/bin/archive-credentials

log "Done."
info "Show it now:   archive-credentials"
info "It prints where each login lives and how to reset it — without ever revealing a password."
