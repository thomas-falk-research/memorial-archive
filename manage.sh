#!/usr/bin/env bash
#
# manage.sh — the one command for the memorial-archive server.
#
# A guided menu so you never have to remember script names. From this folder, run:
#
#     ./manage.sh            (or, if the executable bit was lost on a ZIP download:  bash manage.sh)
#
# It can: check health, install/set up, update, reinstall/repair, uninstall (tools only — never your
# data), and run everyday tasks (ingest · index · backup · status). Run it as your normal user (the
# one with sudo) — NOT with sudo; the individual steps call sudo themselves where needed.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- output helpers --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[1;36m'; c_rst=$'\033[0m'
else c_red=""; c_grn=""; c_yel=""; c_cyn=""; c_rst=""; fi
say()   { printf '%s\n' "$*"; }
title() { printf '\n%s== %s ==%s\n' "$c_cyn" "$*" "$c_rst"; }
ok()    { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn()  { printf '%s!%s %s\n' "$c_yel" "$c_rst" "$*"; }
err()   { printf '%s✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
pause() { read -rp $'\nPress Enter to continue... ' _ || true; }
confirm() { local _a; read -rp "$1 [y/N] " _a || true; [[ "$_a" =~ ^[Yy] ]]; }

[[ "${EUID}" -ne 0 ]] || { err "Please run as your normal user, not with sudo — the steps use sudo themselves."; exit 1; }
[[ -f "$SCRIPT_DIR/archive-doctor.sh" ]] || { err "Run this from the memorial-archive folder (couldn't find the scripts next to it)."; exit 1; }

# Run a repo script via bash, so a missing executable bit (e.g. after a ZIP download) doesn't matter.
run() {
  local s="$1"; shift
  [[ -f "$SCRIPT_DIR/$s" ]] || { err "Missing script: $s"; return 1; }
  printf '\n%s——— %s %s———%s\n' "$c_cyn" "$s" "$*" "$c_rst"
  bash "$SCRIPT_DIR/$s" "$@"
}

# ---- which components are installed (no root needed) -----------------------------------------
have_cmd()       { [[ -x "/usr/local/bin/$1" ]]; }
inst_ingest()    { have_cmd ingest-verify; }
inst_search()    { have_cmd archive-index; }
inst_storage()   { have_cmd archive-storage; }
inst_serve()     { grep -qs 'Digital Archive' /etc/samba/smb.conf; }
inst_webui()     { [[ -f /etc/systemd/system/archive-webui.service ]]; }
inst_immich()    { [[ -d /srv/apps/immich ]]; }
inst_paperless() { [[ -d /srv/apps/paperless ]]; }
inst_copyparty() { [[ -d /srv/apps/copyparty ]]; }
inst_apps()      { have_cmd archive-apps; }
inst_proxy()     { grep -qs 'archive-proxy-setup.sh' /etc/caddy/Caddyfile; }

# ---- actions ---------------------------------------------------------------------------------
do_health() { bash "$SCRIPT_DIR/archive-doctor.sh" || true; }

do_install() {
  title "Install / set up"
  say "Runs the setup steps in order. Each step explains itself and asks before changing anything,"
  say "so you can answer 'n' to skip any you don't want. Re-running later is always safe."
  if confirm "1) Base tooling (Docker, Tailscale, firewall, locale) — run provision?"; then run provision.sh; fi
  if confirm "2) Ingestion core (safe read-only copying + verification)?";            then run archive-ingest-setup.sh; fi
  if confirm "3) Search (full-text + filename)?";                                     then run archive-search-setup.sh; fi
  if confirm "4) Read-only SMB share for iPhones/iPads?";                             then run archive-serve-setup.sh; fi
  if confirm "5) Storage layout + verified backups?";                                 then run archive-storage-setup.sh; fi
  say ""
  say "Optional family-facing apps (Docker):"
  if confirm "6) App manager + shared network (manage all apps from one command)?"; then run archive-apps-setup.sh; fi
  if confirm "7) Phone search web UI?";                            then run archive-webui-setup.sh; fi
  if confirm "8) Photos & videos (Immich)?";                       then run archive-immich-setup.sh; fi
  if confirm "9) Documents (Paperless-ngx)?";                      then run archive-paperless-setup.sh; fi
  if confirm "10) Files web browser (copyparty)?";                 then run archive-copyparty-setup.sh; fi
  if confirm "11) One-URL front door (portal + friendly names)?";  then run archive-proxy-setup.sh; fi
  ok "Install run complete. Tip: choose 'Check health' to verify it all."
}

# Re-run the setup for everything installed. mode '--update' lets app versions advance to the
# latest; mode '--repair' pins each app to the version it is currently running (no version change).
refresh_installed() {
  local mode="$1" v
  inst_ingest  && run archive-ingest-setup.sh  --yes
  inst_search  && run archive-search-setup.sh  --yes
  inst_serve   && run archive-serve-setup.sh   --yes
  inst_storage && run archive-storage-setup.sh --yes
  inst_apps    && run archive-apps-setup.sh    --yes
  inst_webui   && run archive-webui-setup.sh   --yes
  if inst_immich; then
    if [[ "$mode" == "--repair" ]]; then
      v="$(sudo sed -n 's/^IMMICH_VERSION=//p' /srv/apps/immich/.env 2>/dev/null | head -1)"
      [[ -n "$v" ]] && export IMMICH_VERSION="$v"
    fi
    run archive-immich-setup.sh --yes
    unset IMMICH_VERSION
  fi
  if inst_paperless; then
    if [[ "$mode" == "--repair" ]]; then
      v="$(sudo sed -n 's#.*paperless-ngx:##p' /srv/apps/paperless/docker-compose.override.yml 2>/dev/null | head -1)"
      [[ -n "$v" ]] && export PAPERLESS_VERSION="$v"
    fi
    run archive-paperless-setup.sh --yes
    unset PAPERLESS_VERSION
  fi
  if inst_copyparty; then
    if [[ "$mode" == "--repair" ]]; then
      v="$(sudo sed -n 's#.*/ac:##p' /srv/apps/copyparty/docker-compose.yml 2>/dev/null | head -1)"
      [[ -n "$v" ]] && export COPYPARTY_VERSION="$v"
    fi
    run archive-copyparty-setup.sh --yes
    unset COPYPARTY_VERSION
  fi
  inst_proxy && run archive-proxy-setup.sh --yes
  return 0
}

do_update() {
  title "Update"
  say "Pulls the latest scripts, then refreshes everything you have installed. This is a SAFE"
  say "re-run: your passwords, settings, and data are preserved; app versions advance to the latest."
  confirm "Proceed with update?" || { say "Cancelled."; return; }
  if [[ -d "$SCRIPT_DIR/.git" ]]; then
    title "Pulling the latest scripts"
    git -C "$SCRIPT_DIR" pull --ff-only || warn "git pull didn't fast-forward (local edits?) — continuing with the current files."
  else
    warn "This folder isn't a git checkout — skipping pull; refreshing from the current files."
  fi
  refresh_installed --update
  ok "Update complete. Choose 'Check health' to confirm everything is green."
}

do_reinstall() {
  title "Reinstall / repair"
  say "Re-runs the setup for everything installed to repair broken commands/services, WITHOUT"
  say "changing any app versions. Your passwords, settings, and data are preserved."
  confirm "Proceed with reinstall/repair?" || { say "Cancelled."; return; }
  refresh_installed --repair
  ok "Reinstall complete. Choose 'Check health' to confirm."
}

do_uninstall() {
  title "Uninstall"
  warn "This removes the archive TOOLING. It will NEVER touch your archive (/srv/archive) or your"
  warn "backups (/srv/backup), or the fstab entries that mount them — those are left exactly as they are."
  confirm "Continue with uninstall?" || { say "Cancelled."; return; }
  sudo -v || { err "sudo is required to uninstall."; return; }

  if confirm "Remove the installed commands (archive, archive-backup, archive-storage, …)?"; then
    local c
    for c in safe-mount ingest-verify archive-verify archive archive-index archive-search archive-find archive-storage archive-backup archive-apps archive-webui-run; do
      sudo rm -f "/usr/local/bin/$c"
    done
    sudo rm -f /etc/update-motd.d/50-memorial-archive   # the login health banner (installed with storage)
    ok "Removed the /usr/local/bin commands and the login banner."
  fi

  if [[ -f /etc/systemd/system/archive-webui.service ]] && confirm "Stop & remove the search web UI service?"; then
    sudo systemctl disable --now archive-webui 2>/dev/null || true
    sudo rm -f /etc/systemd/system/archive-webui.service
    sudo systemctl daemon-reload 2>/dev/null || true
    ok "Removed the search web UI service."
  fi

  if [[ -f /etc/udev/rules.d/99-archive-no-automount.rules ]] && confirm "Remove the USB auto-mount-disable rule?"; then
    sudo rm -f /etc/udev/rules.d/99-archive-no-automount.rules
    sudo udevadm control --reload-rules 2>/dev/null || true
    ok "Removed the udev rule."
  fi

  local app
  for app in immich paperless copyparty; do
    if [[ -d "/srv/apps/$app" ]] && confirm "Stop & remove the ${app} containers (keeps its data)?"; then
      ( cd "/srv/apps/$app" && sudo docker compose down 2>/dev/null ) || warn "could not stop ${app} (already down?)"
      ok "Stopped the ${app} containers."
    fi
  done

  for app in immich paperless copyparty; do
    if [[ -d "/srv/apps/$app" ]]; then
      warn "Removing /srv/apps/${app} deletes ${app}'s OWN data (its database/thumbnails or OCR'd library)."
      warn "Your ORIGINAL files in /srv/archive are not affected."
      local a; read -rp "Type DELETE to remove /srv/apps/${app}, or press Enter to keep it: " a || true
      if [[ "$a" == "DELETE" ]]; then sudo rm -rf "/srv/apps/${app}"; ok "Removed /srv/apps/${app}."; else say "Kept /srv/apps/${app}."; fi
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    if sudo docker network rm memorial >/dev/null 2>&1; then ok "Removed the shared 'memorial' Docker network."; fi
  fi

  if confirm "Remove saved backup SMB credentials and /etc/archive-ingest.conf (regenerable)?"; then
    sudo rm -f /etc/archive-backup.cred /etc/archive-ingest.conf
    ok "Removed credentials + config."
  fi

  say ""
  warn "Left in place on purpose: your archive (/srv/archive), your backups (/srv/backup), the fstab"
  warn "mounts, the Caddy/Samba config + packages, and Docker itself. Remove those by hand if you truly want to."
}

do_everyday() {
  local ch
  while true; do
    title "Everyday tasks"
    say "  1) Ingest a drive / source   (guided menu)"
    say "  2) Rebuild the search index"
    say "  3) Run a verified backup"
    say "  4) Show storage status"
    say "  5) Manage apps              (status · update · logs)"
    say "  b) Back to the main menu"
    if ! read -rp "Choose: " ch; then return; fi
    case "$ch" in
      1) if have_cmd archive;        then archive;        else err "Not installed — run Install (ingest) first."; fi ;;
      2) if have_cmd archive-index;  then archive-index;  else err "Not installed — run Install (search) first."; fi ;;
      3) if have_cmd archive-backup; then archive-backup; else err "Not installed — run Install (storage) first."; fi ;;
      4) if have_cmd archive-storage;then archive-storage;else err "Not installed — run Install (storage) first."; fi ;;
      5) if have_cmd archive-apps; then
           archive-apps status
           confirm "Update all apps now (pull newer images + recreate)?" && archive-apps update
         else err "Not installed — run Install (app manager) first."; fi ;;
      b|B|q|Q) return ;;
      *) warn "Please pick 1-5 or b." ;;
    esac
    pause
  done
}

# ---- main menu -------------------------------------------------------------------------------
while true; do
  printf '\n%s╭───── Memorial Archive — Manager ─────╮%s\n' "$c_cyn" "$c_rst"
  say "  1) Check health        — verify everything"
  say "  2) Install / set up    — first-time setup"
  say "  3) Update              — pull latest + refresh (safe; advances app versions)"
  say "  4) Reinstall / repair  — re-run setup, no version change"
  say "  5) Uninstall           — remove the tools only (never your data)"
  say "  6) Everyday tasks      — ingest · index · backup · status"
  say "  q) Quit"
  if ! read -rp "Choose: " choice; then say ""; say "Goodbye."; exit 0; fi
  case "$choice" in
    1) do_health ;;
    2) do_install ;;
    3) do_update ;;
    4) do_reinstall ;;
    5) do_uninstall ;;
    6) do_everyday ;;
    q|Q) say "Goodbye."; exit 0 ;;
    *) warn "Please pick 1-6, or q to quit." ;;
  esac
  pause
done
