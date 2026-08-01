#!/usr/bin/env bash
# probe-paperless-state.sh — READ-ONLY census for the Paperless "Documents view" design.
#
# Answers the six questions docs/PAPERLESS-DOCUMENT-VIEW.md §9 says we must measure before feeding
# Paperless anything:
#   1. is Paperless installed, at what version, and is the v2->v3 database-layout hazard armed?
#   2. how much RAM is actually free right now, with Immich running?
#   3. how much free space is on the OS disk (Paperless stores ~2x what it consumes) and the archive?
#   4. how many DOCUMENT-shaped files exist (counts + bytes by type, per top-level area)?
#   5. how much of that is exactly redundant (cheap upper bound on duplicates)?
#   6. how much have we already OCR'd?
#
# WRITES NOTHING. Opens nothing for write, creates no files, starts/stops no containers, touches no
# masters. Redacts anything that looks like a secret. Uses your docker-group access (no sudo); the
# few root-only facts are skipped with a note rather than escalating.
#
# Usage:   bash probe-paperless-state.sh            # full census (the size pass can take minutes)
#          SKIP_SIZES=1 bash probe-paperless-state.sh   # counts only, no per-file stat pass
# Then paste the whole output back.
set -uo pipefail

ARC="${ARC:-/srv/archive}"
APPS="${APPS:-/srv/apps}"
SKIP_SIZES="${SKIP_SIZES:-0}"

sep()  { printf '\n========== %s ==========\n' "$1"; }
note() { printf '    %s\n' "$*"; }
redact() { sed -E 's/((pass(word)?|secret|token|jwt|key|admin_pw)[[:space:]=:]+)[^[:space:]]+/\1<REDACTED>/Ig'; }
have_docker() { command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; }
human() { awk -v b="${1:-0}" 'BEGIN{u="B KiB MiB GiB TiB"; split(u,a," "); i=1; while(b>=1024&&i<5){b/=1024;i++} printf "%.1f %s", b, a[i]}'; }

printf 'probe-paperless-state — %s on %s\n' "$(date -Is 2>/dev/null)" "$(hostname -s 2>/dev/null)"
printf 'READ-ONLY: this script writes nothing.\n'

# ------------------------------------------------------------------------------------------------
sep "1. PAPERLESS INSTALL STATE (and whether the v2->v3 hazard is armed)"
PDIR="$APPS/paperless"
if [[ ! -d "$PDIR" ]]; then
  note "NOT INSTALLED — no $PDIR. (Fresh install: the v3 migration hazard does not apply.)"
else
  note "install dir: $PDIR"
  if [[ -r "$PDIR/docker-compose.override.yml" ]]; then
    tag="$(sed -n 's#.*paperless-ngx:##p' "$PDIR/docker-compose.override.yml" 2>/dev/null | head -1 | tr -d '[:space:]')"
    note "pinned app version (override):  ${tag:-<none found>}"
  else
    note "no docker-compose.override.yml readable by you (try: sudo cat $PDIR/docker-compose.override.yml)"
  fi
  if [[ -r "$PDIR/docker-compose.yml" ]]; then
    dbimg="$(awk '/^[[:space:]]{2}db:[[:space:]]*$/{i=1;next} i&&/^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/{i=0} i&&$1=="image:"{print $2;exit}' "$PDIR/docker-compose.yml")"
    pgmnt="$(grep -oE 'pgdata:/[^"'"'"'[:space:]]*' "$PDIR/docker-compose.yml" | head -1)"
    brk="$(awk '/^[[:space:]]{2}broker:[[:space:]]*$/{i=1;next} i&&/^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/{i=0} i&&$1=="image:"{print $2;exit}' "$PDIR/docker-compose.yml")"
    note "database image:  ${dbimg:-?}"
    note "pgdata mount:    ${pgmnt:-?}      <-- if this is 'pgdata:/var/lib/postgresql/data', a v3"
    note "broker image:    ${brk:-?}            compose (which mounts 'pgdata:/var/lib/postgresql')"
    note "                                      would start a BLANK database. See §2 of the design doc."
  else
    note "docker-compose.yml not readable by you (try: sudo cat $PDIR/docker-compose.yml)"
  fi
  if [[ -r "$PDIR/docker-compose.env" ]]; then
    printf '    -- docker-compose.env (secrets redacted) --\n'
    grep -vE '^\s*(#|$)' "$PDIR/docker-compose.env" 2>/dev/null | redact | sed 's/^/      /'
  else
    note "docker-compose.env not readable by you (expected: it is chmod 600)."
  fi
  printf '    -- export present? (the fallback an upgrade requires) --\n'
  if [[ -e "$PDIR/export/manifest.json" ]]; then
    note "export/manifest.json exists, modified $(date -r "$PDIR/export/manifest.json" -Is 2>/dev/null)"
  else
    note "NO export/manifest.json — no rollback point. Take one before ANY version change:"
    note "  cd $PDIR && sudo docker compose exec -T webserver document_exporter ../export"
  fi
  printf '    -- consume/ must be EMPTY at rest (anything sitting there gets eaten and deleted) --\n'
  if [[ -d "$PDIR/consume" ]]; then
    note "consume/ holds $(find "$PDIR/consume" -type f 2>/dev/null | wc -l) file(s)"
  else
    note "no consume/ directory"
  fi
fi

# The ground truth the compose can't tell us: where PGDATA really is inside the volume.
if have_docker; then
  dbc="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'paperless.*db|db.*paperless' | head -1)"
  if [[ -n "$dbc" ]]; then
    printf '    -- live database container (%s) --\n' "$dbc"
    note "PGDATA env:    $(docker exec "$dbc" sh -c 'echo "${PGDATA:-<unset>}"' 2>/dev/null)"
    note "server version: $(docker exec "$dbc" sh -c 'postgres --version' 2>/dev/null)"
    for p in /var/lib/postgresql/data/PG_VERSION /var/lib/postgresql/PG_VERSION; do
      v="$(docker exec "$dbc" sh -c "cat $p 2>/dev/null" 2>/dev/null)"
      [[ -n "$v" ]] && note "on-disk cluster version at $p: $v"
    done
  else
    note "(no running Paperless database container found — start it, or this fact stays unknown)"
  fi
fi

# ------------------------------------------------------------------------------------------------
sep "2. MEMORY HEADROOM (the binding constraint — Immich is already resident)"
free -h 2>/dev/null | sed 's/^/    /'
printf '    MemAvailable: %s kB\n' "$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)"
printf '    swap in use : %s\n' "$(free -h 2>/dev/null | awk '/Swap/{print $3" of "$2}')"
printf '    load        : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
printf '    cpus        : %s\n' "$(nproc 2>/dev/null)"
if have_docker; then
  printf '    -- per-container memory (docker stats, one shot) --\n'
  docker stats --no-stream --format '      {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' 2>/dev/null \
    | sort | head -40
fi

# ------------------------------------------------------------------------------------------------
sep "3. DISK (Paperless keeps original + OCR'd archive PDF: budget ~2x what we feed it)"
df -h / "$ARC" /srv/backup 2>/dev/null | sed 's/^/    /'
if have_docker; then
  printf '    -- docker disk usage --\n'
  docker system df 2>/dev/null | sed 's/^/      /'
fi

# ------------------------------------------------------------------------------------------------
sep "4. CANDIDATE DOCUMENT CENSUS (what a curated Paperless corpus could be drawn from)"
# Counts come from the plocate database (fast, no tree walk). images/ is deliberately excluded: it
# holds photo/forensic masters and is Immich's/forensics' territory, not Paperless's.
PLDB="$ARC/.plocate.db"
CAND="$(mktemp)"; trap 'rm -f "$CAND" "${SIZES:-}"' EXIT   # our own temp files only, cleaned up
if command -v plocate >/dev/null 2>&1 && [[ -r "$PLDB" ]]; then
  note "source: plocate db ($PLDB)"
  plocate -d "$PLDB" -i --regex '\.(pdf|tif|tiff|png|jpg|jpeg|gif|bmp|doc|docx|xls|xlsx|rtf|txt|eml|msg)$' 2>/dev/null >"$CAND"
else
  note "source: find (plocate db unreadable) — this walk can take a few minutes"
  for sub in incoming recovered .derived; do
    [[ -d "$ARC/$sub" ]] && find "$ARC/$sub" -type f \( \
      -iname '*.pdf' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.png' -o -iname '*.jpg' \
      -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.doc' -o -iname '*.docx' \
      -o -iname '*.xls' -o -iname '*.xlsx' -o -iname '*.rtf' -o -iname '*.txt' -o -iname '*.eml' \
      -o -iname '*.msg' \) 2>/dev/null
  done >"$CAND"
fi

printf '    %-12s %-30s %10s\n' 'AREA' 'CLASS' 'FILES'
awk -v arc="$ARC" '
  index($0, arc "/") != 1 { next }
  {
    rest = substr($0, length(arc) + 2); split(rest, a, "/"); top = a[1];
    if (top != "incoming" && top != "recovered" && top != ".derived") next;
    ext = tolower($0); sub(/.*\./, "", ext);
    if      (ext == "pdf")                                cls = "pdf"
    else if (ext ~ /^(tif|tiff)$/)                     cls = "tiff-scan"
    else if (ext ~ /^(png|gif|bmp)$/)                  cls = "img-scanlike"
    else if (ext ~ /^(jpg|jpeg)$/)                     cls = "img-photolike"
    else if (ext ~ /^(doc|docx|xls|xlsx|rtf)$/)        cls = "office(needs-tika-or-convert)"
    else if (ext == "txt")                             cls = "text"
    else if (ext ~ /^(eml|msg)$/)                      cls = "mail"
    else                                               next
    n[top SUBSEP cls]++; tot[cls]++; grand++
  }
  END {
    # A/B/C prefixes keep the sections in order through the external sort, then get stripped.
    for (k in n) { split(k, p, SUBSEP); printf "A\t    %-12s %-30s %10d\n", p[1], p[2], n[k] }
    for (c in tot) printf "B\t    %-12s %-30s %10d\n", "ALL", c, tot[c]
    printf "C\t    %-12s %-30s %10d\n", "ALL", "TOTAL candidates", grand
  }' "$CAND" | sort -t$'\t' -k1,1 -k2,2 | cut -f2-

printf '\n    Feedable to Paperless as installed (no Tika): pdf + tiff-scan + img-* .\n'
printf '    office(*) needs Tika/Gotenberg (+RAM) or pre-conversion to PDF — see design doc §5.\n'
printf '    img-photolike is where PHOTOGRAPHS hide: do not feed it wholesale (Immich owns photos).\n'

# ------------------------------------------------------------------------------------------------
sep "5. REDUNDANCY PRESSURE (cheap upper bound on exact duplicates)"
if [[ "$SKIP_SIZES" == "1" ]]; then
  note "skipped (SKIP_SIZES=1)."
else
  note "stat'ing the pdf/tiff/image candidates — a few minutes on the HDD, reads only..."
  SIZES="$(mktemp)"
  grep -iE '\.(pdf|tif|tiff|png|jpg|jpeg|gif|bmp)$' "$CAND" 2>/dev/null \
    | tr '\n' '\0' | xargs -0 -r stat --printf '%s\n' 2>/dev/null >"$SIZES"
  awk '
    $1 > 0 { n++; bytes += $1; c[$1]++ }
    END {
      dup = 0; for (s in c) if (c[s] > 1) dup += c[s] - 1
      printf "    files measured        : %d\n", n
      printf "    total bytes           : %.2f GiB\n", bytes/1073741824
      printf "    same-size collisions  : %d files (%.1f%%)  <-- UPPER BOUND on exact duplicates\n", dup, (n ? dup*100/n : 0)
      printf "    distinct sizes        : %d\n", length(c)
    }' "$SIZES"
  note "Same size != same bytes; the real dedup is by SHA-256 at copy time. This just sizes the prize:"
  note "every duplicate skipped is an OCR job (seconds to minutes of CPU) we never have to run."
fi

# ------------------------------------------------------------------------------------------------
sep "6. WHAT WE ALREADY OCR'd (reusable for scan-vs-photo and estate-term selection)"
DER="$ARC/.derived"
if [[ -d "$DER" ]]; then
  if [[ "$SKIP_SIZES" == "1" ]]; then
    note "(du skipped: SKIP_SIZES=1)"
  else
    note "measuring .derived size (walks the tree; a minute or so on the HDD, reads only)..."
    du -sh "$DER" 2>/dev/null | sed 's/^/    /'
  fi
  for d in "$DER"/*/; do
    [[ -d "$d" ]] || continue
    printf '    %-40s %s entries\n' "$(basename "$d")/" "$(find "$d" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)"
  done
  printf '    OCR sidecar text files (*.txt under .derived): %s\n' \
    "$(find "$DER" -type f -name '*.txt' 2>/dev/null | wc -l)"
else
  note "no $DER"
fi

# ------------------------------------------------------------------------------------------------
sep "7. NEIGHBOURING SERVICES (what Paperless must not destabilise)"
if have_docker; then
  docker ps --format '    {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | sort
else
  note "docker not usable by this user without sudo — skipping"
fi
for a in immich copyparty czkawka stirling docmost kopia; do
  [[ -d "$APPS/$a" ]] && printf '    installed: %s\n' "$a"
done

printf '\nprobe done — writes nothing. Paste the whole block back.\n'
