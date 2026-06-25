#!/usr/bin/env bash
# discover-state.sh — READ-ONLY census of how the archive and its three front-ends (copyparty, recoll,
# Immich) are wired, so we can design a safe "everything in sync" pipeline without touching masters or
# breaking the running family services. Writes NOTHING. Redacts obvious secrets before printing.
# Run on the box and paste the whole output back.
set -uo pipefail
ARC="${ARC:-/srv/archive}"
HOME="${HOME:-/home/tom}"
sep(){ printf '\n========== %s ==========\n' "$1"; }
# defense-in-depth: mask passwords/secrets/tokens and copyparty -a user:pass before anything is printed
redact(){ sed -E 's/((pass(word)?|secret|token|jwt|key)[[:space:]=:]+)[^[:space:]]+/\1<REDACTED>/Ig; s/(-a[[:space:]=]+)[^[:space:]]+/\1<REDACTED>/g'; }

sep "WHO AM I / SUDO"
id
echo "groups: $(groups 2>/dev/null)"
if sudo -n true 2>/dev/null; then echo "sudo: AVAILABLE non-interactively"
else echo "sudo: not available without a password (that's fine — just tells us the perms approach)"; fi

sep "DISK SPACE"
df -h "$ARC" "$HOME" / 2>/dev/null | sort -u

sep "ARCHIVE OWNERSHIP / PERMS"
ls -ld "$ARC" 2>/dev/null
find "$ARC" -maxdepth 1 -mindepth 1 -printf '%M %u:%g  %p\n' 2>/dev/null | sort -k3
echo "-- can THIS user write to each? --"
for d in "$ARC" "$ARC/recovered" "$ARC/images" "$ARC/incoming" "$ARC/.derived" "$ARC/.recoll"; do
  if [ -e "$d" ]; then [ -w "$d" ] && echo "WRITABLE   $d" || echo "read-only  $d"; else echo "absent     $d"; fi
done

sep "ARCHIVE TOOLING (how it writes to the root)"
for c in archive-index archive-search archive-find; do
  p="$(command -v "$c" 2>/dev/null)"; echo "$c -> ${p:-NOT FOUND}"
done
ai="$(command -v archive-index 2>/dev/null)"
[ -n "$ai" ] && { echo "----- $ai (first 80 lines) -----"; sed -n '1,80p' "$ai" | redact; }

sep "RECOLL: version, config, image-OCR capability"
( recoll --version 2>/dev/null || true ) | head -1
dpkg-query -W -f='recoll pkg version: ${Version}\n' recoll 2>/dev/null || true
for cd in "$HOME/.recoll" "$ARC/.recoll" /root/.recoll; do
  if [ -f "$cd/recoll.conf" ]; then
    echo "-- $cd/recoll.conf (non-comment lines) --"
    grep -vE '^\s*($|#)' "$cd/recoll.conf" | redact
    echo "   (xapiandb size: $(du -sh "$cd/xapiandb" 2>/dev/null | cut -f1 || echo '?'))"
  fi
done
echo "-- does this recoll build ship an image-OCR filter? --"
ls /usr/share/recoll/filters 2>/dev/null | grep -iE 'ocr|tesseract' || echo "(no ocr filter script found under /usr/share/recoll/filters)"
command -v tesseract >/dev/null && echo "tesseract: $(tesseract --version 2>&1 | head -1)"

sep "COPYPARTY (how the web root is served: volume / RO-RW / port)"
ps -eo args 2>/dev/null | grep -i '[c]opyparty' | redact || echo "no running copyparty process found"
systemctl cat copyparty 2>/dev/null | grep -iE 'ExecStart|WorkingDirectory|User=' | redact || echo "(no copyparty systemd unit visible)"
for f in /etc/copyparty.conf "$HOME/.config/copyparty/copyparty.conf" "$HOME/copyparty.conf"; do
  [ -f "$f" ] && { echo "-- $f (volume/port lines only) --"; grep -inE '/srv|:rw|:r,|:r$|:A|accs|share|^\s*\[/|port|:3923' "$f" | redact; }
done

sep "IMMICH (deployment + library/upload paths)"
if command -v docker >/dev/null; then
  docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | grep -i immich \
    || echo "no immich containers via 'docker ps' (try: sudo docker ps | grep immich)"
fi
for f in "$HOME"/immich/.env /opt/immich/.env /srv/immich/.env "$HOME"/immich-app/.env; do
  [ -f "$f" ] && { echo "-- $f --"; grep -iE 'UPLOAD_LOCATION|EXTERNAL|LIBRARY|IMMICH_VERSION|DB_DATA' "$f" | redact; }
done
for f in "$HOME"/immich/docker-compose.yml /opt/immich/docker-compose.yml /srv/immich/docker-compose.yml "$HOME"/immich-app/docker-compose.yml; do
  [ -f "$f" ] && { echo "-- volumes in $f --"; grep -nE '^\s*-\s+/|/srv|/mnt|:ro|:/usr/src' "$f" | redact; }
done

sep "DERIVED ARTIFACTS ALREADY PRESENT"
for d in "$HOME/ocr-out" "$HOME/estate-view" "$ARC/recovered/estate-view" "$ARC/.derived"; do
  [ -e "$d" ] && printf '%-40s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1) / $(find "$d" -type f 2>/dev/null | wc -l) files"
done

sep "CORPUS SIZES (planning scope for OCR + Immich)"
for d in images incoming recovered; do
  [ -d "$ARC/$d" ] && printf '%-12s %s\n' "$d" "$(du -sh "$ARC/$d" 2>/dev/null | cut -f1)"
done

echo; echo "discovery done — paste this whole block back. (Secrets were redacted before printing.)"
