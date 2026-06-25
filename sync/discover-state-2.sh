#!/usr/bin/env bash
# discover-state-2.sh — READ-ONLY follow-up probe. Three facts the in-sync design still needs:
#   (1) what copyparty actually SERVES (host volume, read-only vs read-write, dotfile visibility)
#   (2) how Immich is mounted + where its library/upload live (for an in-place external library)
#   (3) how many real document-scans hide in the recoll-indexed tree (to size an OCR pass)
# Writes nothing. Redacts secrets. Uses your docker-group access (no sudo needed).
set -uo pipefail
ARC="${ARC:-/srv/archive}"
sep(){ printf '\n========== %s ==========\n' "$1"; }
redact(){ sed -E 's/((pass(word)?|secret|token|jwt|key)[[:space:]=:]+)[^[:space:]]+/\1<REDACTED>/Ig'; }
have_docker(){ command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; }

sep "COPYPARTY: container, mounts, served volumes, dotfile visibility"
if have_docker; then
  cp="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i copyparty | head -1 | awk '{print $1}')"
  if [ -n "$cp" ]; then
    echo "container: $cp"
    echo "-- mounts (host -> container, RW?) --"
    docker inspect "$cp" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} (RW={{.RW}}){{"\n"}}{{end}}' 2>/dev/null
    echo "-- served volumes / perms / flags (filtered from /z/initcfg) --"
    docker exec "$cp" cat /z/initcfg 2>/dev/null | grep -inE '^\s*\[|accs|^\s*[ru]+:|:r|:rw|:A|dots|see|port|^\s*-' | redact | head -70
  else
    echo "no copyparty container found in 'docker ps' (host process?)"
  fi
else
  echo "docker not usable by this user (would need sudo) — skipping"
fi

sep "IMMICH: compose dir, library/upload paths, archive mounts"
if have_docker; then
  proj="$(docker inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
  echo "compose working_dir: ${proj:-unknown}"
  if [ -n "$proj" ] && [ -f "$proj/.env" ]; then
    echo "-- .env (relevant keys) --"
    grep -iE 'UPLOAD_LOCATION|EXTERNAL|LIBRARY|DB_DATA_LOCATION|IMMICH_VERSION' "$proj/.env" | redact
  fi
  echo "-- immich_server mounts (host -> container, RW?) --"
  docker inspect immich_server --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} (RW={{.RW}}){{"\n"}}{{end}}' 2>/dev/null
else
  echo "docker not usable without sudo — skipping"
fi

sep "OCR SCOPE: image files in the recoll-indexed tree (incoming/recovered/.derived; images/ is skipped)"
PLDB="$ARC/.plocate.db"
bucket_awk='
  index($0, arc"/")==1 {
    rest=substr($0, length(arc)+2); split(rest, a, "/"); top=a[1];
    if (top!="incoming" && top!="recovered" && top!=".derived") next;
    ext=tolower($0); gsub(/.*\./,"",ext);
    scan = (ext ~ /^(tif|tiff|png|gif|bmp)$/);
    tot[top]++; if(scan) scn[top]++; else pho[top]++;
  }
  END{ for(s in tot) printf "%-10s total=%-8d scan-like(tif/png/gif/bmp)=%-8d photo-like(jpg)=%-8d\n", s, tot[s], scn[s]+0, pho[s]+0 }'
if command -v plocate >/dev/null 2>&1 && [ -r "$PLDB" ]; then
  echo "(via plocate db — fast)"
  plocate -d "$PLDB" -i --regex '\.(tif|tiff|png|gif|jpg|jpeg|bmp)$' 2>/dev/null | awk -F/ -v arc="$ARC" "$bucket_awk"
else
  echo "(via find — may take a few minutes)"
  for sub in incoming recovered .derived; do
    [ -d "$ARC/$sub" ] && find "$ARC/$sub" -type f \( -iname '*.tif' -o -iname '*.tiff' -o -iname '*.png' \
      -o -iname '*.gif' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.bmp' \) -printf '%p\n' 2>/dev/null
  done | awk -F/ -v arc="$ARC" "$bucket_awk"
fi
echo "NOTE: image attachments embedded INSIDE mbox files are not counted here — recoll sees those as"
echo "sub-documents at index time, and they are exactly the fax/will scans we want it to OCR."

echo; echo "probe-2 done — paste the whole block back."
