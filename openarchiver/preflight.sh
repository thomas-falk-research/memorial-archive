#!/usr/bin/env bash
#
# openarchiver/preflight.sh — one read-only command that establishes the true state of archive-pc
# before the real ingestion starts.
#
# WHY IT EXISTS
#   Coming back to this after a break, the dangerous thing is not disagreement — it is two people
#   confidently remembering different boxes. This measures, in one pass, every property the
#   ingestion plan depends on, and prints them as facts rather than recollections.
#
# WHAT IT CHECKS  (the section letters are referenced by the summary at the end)
#   A repo       is the checkout on this box the code we think it is
#   B release    is the RUNNING image the release we intend, and is that still the current upstream
#   C stack      are all five services actually alive, including the backend that once died silently
#   D config     hardening, and the settings that decide whether a scanned will is found or dropped
#   E secrets    are the unregenerable keys provably off the box yet
#   F ingestion  exactly what test data and which sources exist, so "clear the experiments" has a
#                known scope instead of a hopeful one
#   G network    can this actually be reached over LAN and Tailscale, and does ORIGIN match how it
#                will be reached — get this wrong and logins break
#   H box        disk, memory and headroom against the projected corpus
#
# WHAT IT NEVER DOES
#   It changes nothing. No writes outside a scratch directory, no container restarts, no config
#   edits, no imports, no deletions. Every finding is an observation or an explicit UNKNOWN — an
#   answer this script could not obtain is reported as UNKNOWN and counts AGAINST readiness. It
#   never infers a property it did not see.
#
# Usage
#   bash openarchiver/preflight.sh              # everything
#   bash openarchiver/preflight.sh --no-network # skip the upstream release lookup (offline box)
#   bash openarchiver/preflight.sh --brief      # summary only
#
set -uo pipefail

APP_DIR="${OPENARCHIVER_DIR:-/srv/apps/openarchiver}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
REPO_DIR="${REPO_DIR:-}"
PORT="${OPENARCHIVER_PORT:-3010}"
PG="openarchiver-postgres"
PSQL_DB="${PSQL_DB:-open_archive}"
PSQL_USER="${PSQL_USER:-openarchiver}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/LogicLabs-OU/OpenArchiver}"
OA_IMAGE_REPO="${OA_IMAGE_REPO:-logiclabshq/open-archiver}"
DO_NETWORK=1
BRIEF=0
BACKUP_VERIFIED=""
RV_MODE=0; RV_RUNNING=""; RV_GIT=""; RV_REG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-network) DO_NETWORK=0 ;;
    --brief) BRIEF=1 ;;
    # Assert that you have verified an off-box copy of .env with THIS digest. Not blind trust:
    # the digest is re-checked against the live file, so a backup taken before a re-key is caught.
    --env-backup-verified) shift; BACKUP_VERIFIED="${1:-}" ;;
    # Hidden: exercise the release comparison with supplied values. The network path cannot be
    # driven from a drill, and an untested comparison is how the last wrong answer got believed.
    --release-verdict) shift; RV_RUNNING="${1:-}"; shift; RV_GIT="${1:-}"; shift; RV_REG="${1:-}"; RV_MODE=1 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
say(){ [ "$BRIEF" -eq 1 ] || printf '%s\n' "$*"; }
hdr(){ [ "$BRIEF" -eq 1 ] || printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }

# Three outcomes, deliberately. UNKNOWN is not a pass: a property this script could not observe is
# a property nobody has observed, and the whole point of the exercise is to stop assuming.
n_ok=0; n_bad=0; n_unk=0
declare -a BLOCKERS=() UNKNOWNS=()
ok(){   n_ok=$((n_ok+1));  [ "$BRIEF" -eq 1 ] || printf '  %sOK%s      %s\n' "$c_g" "$c_0" "$*"; }
bad(){  n_bad=$((n_bad+1)); BLOCKERS+=("$1"); [ "$BRIEF" -eq 1 ] || printf '  %sBLOCK%s   %s\n' "$c_r" "$c_0" "$*"; }
unk(){  n_unk=$((n_unk+1)); UNKNOWNS+=("$1"); [ "$BRIEF" -eq 1 ] || printf '  %sUNKNOWN%s %s\n' "$c_y" "$c_0" "$*"; }
note(){ [ "$BRIEF" -eq 1 ] || printf '          %s\n' "$*"; }

have(){ command -v "$1" >/dev/null 2>&1; }

# bind_ok <ip> — the only two interfaces this stack may publish on.
#
# Loopback, or this host's Tailscale address. Tailscale hands out CGNAT space, 100.64.0.0/10, i.e.
# 100.64.x.x through 100.127.x.x — matching a bare "100." prefix would also accept 100.200.x.x,
# which is ordinary PUBLIC address space, so the check would quietly permit a public bind while
# looking like it had been tightened.
bind_ok(){
  [ "$1" = "127.0.0.1" ] && return 0
  case "$1" in
    100.*)
      local o2="${1#100.}"; o2="${o2%%.*}"
      case "$o2" in ''|*[!0-9]*) return 1 ;; esac
      [ "$o2" -ge 64 ] && [ "$o2" -le 127 ] && return 0 ;;
  esac
  return 1
}


# registry_latest <repo> — the newest vN.N.N tag in the CONTAINER REGISTRY, which is what we
# actually deploy. Independent of git, so it corroborates rather than echoes. Version-sorted
# client-side because the registry's own ordering parameter is not dependable.
registry_latest(){
  have curl || return 1
  have python3 || return 1
  local url="https://hub.docker.com/v2/repositories/$1/tags?page_size=100"
  local page=0 tmp; tmp="$(mktemp -d)" || return 1
  while [ -n "$url" ] && [ "$page" -lt 5 ]; do
    curl -s --max-time 30 "$url" -o "$tmp/p.json" 2>/dev/null || break
    [ -s "$tmp/p.json" ] || break
    python3 - "$tmp/p.json" "$tmp/names" "$tmp/next" <<'PYEOF' 2>/dev/null || break
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], "a").write("\n".join(r.get("name", "") for r in d.get("results", [])) + "\n")
open(sys.argv[3], "w").write(d.get("next") or "")
PYEOF
    url="$(cat "$tmp/next" 2>/dev/null)"
    page=$((page+1))
  done
  local out=""
  [ -s "$tmp/names" ] && out="$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' "$tmp/names" | sort -V | tail -1)"
  rm -rf "$tmp"
  [ -n "$out" ] && printf '%s' "$out"
}


# app_base_url — where the app is reachable FROM THIS HOST, read from the deployed compose rather
# than assumed.
#
# This used to be hard-coded to 127.0.0.1. Once the tailnet bind option existed, the app stopped
# being on loopback and every host-side probe reported a perfectly healthy stack as dead (HTTP 000)
# — a check failing for a reason that has nothing to do with the property it is testing, which is
# the most expensive kind of wrong answer. The published bind is the authority, so ask it.
app_base_url(){
  local b p
  b="$(sudo sed -n 's/.*"\([0-9.]*\):\([0-9]*\):3000".*/\1/p' "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1)"
  p="$(sudo sed -n 's/.*"\([0-9.]*\):\([0-9]*\):3000".*/\2/p' "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1)"
  [ -n "$b" ] || b="127.0.0.1"
  [ -n "$p" ] || p="$PORT"
  printf 'http://%s:%s' "$b" "$p"
}

dk(){ sudo docker "$@" 2>/dev/null; }
q(){ sudo docker exec "$PG" psql -U "$PSQL_USER" -d "$PSQL_DB" -tAc "$1" 2>/dev/null | tr -d '\r'; }
q1(){ q "$1" | head -1 | tr -d '[:space:]'; }

have sudo || { printf 'FATAL sudo is required (to read the running config).\n' >&2; exit 2; }
have docker || { printf 'FATAL docker is not installed — this is not the archive-pc stack.\n' >&2; exit 2; }

# ------------------------------------------------------------------------------------------------
hdr "A · REPO — is the code on this box what we think it is"

if [ -z "$REPO_DIR" ]; then
  for cand in "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" "$HOME/memorial-archive" /root/memorial-archive; do
    [ -d "${cand:-/nonexistent}/.git" ] && { REPO_DIR="$cand"; break; }
  done
fi

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR/.git" ]; then
  unk "could not locate the memorial-archive checkout (set REPO_DIR=...)"
else
  say "  checkout: $REPO_DIR"
  branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  head="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"
  subject="$(git -C "$REPO_DIR" log -1 --pretty=%s 2>/dev/null)"
  ok "branch $branch at $head"
  note "$subject"

  if [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    bad "the checkout has UNCOMMITTED changes — you are not running the reviewed code"
    git -C "$REPO_DIR" status --short 2>/dev/null | sed 's/^/          /'
  else
    ok "working tree clean"
  fi

  # Does the checkout carry the tooling this plan depends on? Naming the files is a far more
  # useful answer than a commit hash nobody can check against from memory.
  missing=""
  for f in openarchiver/backup-env.sh openarchiver/preflight.sh openarchiver/verify-openarchiver.sh \
           openarchiver/stage-mailbox.sh openarchiver/dedup-experiment.sh openarchiver/inventory-mailboxes.sh; do
    [ -f "$REPO_DIR/$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    bad "the checkout is missing tooling this plan needs:$missing"
    note "git -C $REPO_DIR fetch origin && git -C $REPO_DIR checkout <branch> && git -C $REPO_DIR pull"
  else
    ok "all six Open Archiver tools present in the checkout"
  fi
fi

# ------------------------------------------------------------------------------------------------
hdr "B · RELEASE — is the running image the release we intend"

[ -d "$APP_DIR" ] || { bad "no Open Archiver install at $APP_DIR"; }

running_tag=""
if [ -d "$APP_DIR" ]; then
  running_tag="$(dk inspect openarchiver-app --format '{{.Config.Image}}' | sed 's|.*:||')"
  compose_tag="$(sudo grep -oE 'open-archiver:[^[:space:]"]+' "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1 | sed 's|.*:||')"
  if [ -n "$running_tag" ]; then
    ok "running image tag: $running_tag"
  else
    unk "could not read the running image tag (is openarchiver-app up?)"
  fi
  if [ -n "$compose_tag" ] && [ -n "$running_tag" ]; then
    if [ "$compose_tag" = "$running_tag" ]; then
      ok "compose and the running container agree ($compose_tag)"
    else
      bad "DRIFT: compose says $compose_tag but the running container is $running_tag"
      note "the container was not recreated after the compose file changed"
    fi
  fi
fi

if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/archive-openarchiver-setup.sh" ]; then
  pinned="$(sed -n 's/^FALLBACK_VERSION="\(.*\)".*/\1/p' "$REPO_DIR/archive-openarchiver-setup.sh" | head -1)"
  if [ -n "$pinned" ] && [ -n "$running_tag" ]; then
    if [ "$pinned" = "$running_tag" ]; then
      ok "matches the repo's recorded pin ($pinned)"
    else
      bad "the repo pins $pinned but $running_tag is running"
    fi
  fi
fi

if [ "$DO_NETWORK" -eq 1 ] || [ "$RV_MODE" -eq 1 ]; then
  if [ "$RV_MODE" -eq 1 ]; then
    git_latest="$RV_GIT"; reg_latest="$RV_REG"; running_tag="$RV_RUNNING"
  else
    git_latest="$(timeout 45 git ls-remote --tags --refs "$UPSTREAM_REPO" 'v*' 2>/dev/null \
                  | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
    reg_latest="$(registry_latest "$OA_IMAGE_REPO")"
  fi

  if [ -z "$git_latest" ] && [ -z "$reg_latest" ]; then
    unk "could not reach either source to establish the current release (offline? use --no-network)"
  elif [ -n "$git_latest" ] && [ -n "$reg_latest" ] && [ "$git_latest" != "$reg_latest" ]; then
    # THE STALE-ANSWER DETECTOR, and the reason this check asks twice.
    #
    # A single `git ls-remote` in this project once returned v0.5.2 as the newest tag while v0.6.0
    # had been released eleven days earlier — a cached answer, reported as fact, believed, and
    # written into an assessment. Two independent sources cannot both be stale in the same
    # direction without it showing up here.
    unk "the two sources DISAGREE on the current release — one of them is stale"
    note "  git tags say : ${git_latest}"
    note "  the registry says: ${reg_latest}"
    note "Believe neither until they agree. A cached ls-remote reported an old release as current"
    note "in this project once already, and nothing caught it because nothing else was asked."
    note "  newer of the two: $(printf '%s\n%s\n' "$git_latest" "$reg_latest" | sort -V | tail -1)"
  else
    latest="${reg_latest:-$git_latest}"
    corroborated="both git and the registry"
    if [ -z "$git_latest" ] || [ -z "$reg_latest" ]; then
      corroborated="only one source (the other was unreachable)"
    fi
    if [ -z "$running_tag" ]; then
      unk "current release is $latest per $corroborated, but the running tag is unknown"
    elif [ "$latest" = "$running_tag" ]; then
      if [ "$corroborated" = "both git and the registry" ]; then
        ok "on the current release ($latest), confirmed by git tags AND the registry"
      else
        unk "appears current ($latest) but confirmed by $corroborated — weaker evidence"
      fi
    else
      # Not a blocker. The pin exists so the version never moves without a decision.
      unk "upstream has $latest; we run $running_tag — a DECISION to make, not a defect"
      note "  confirmed by $corroborated"
      note "  upgrading costs a re-verify of every gate; read the changelog before deciding"
    fi
  fi
  [ "$RV_MODE" -eq 1 ] && { printf '\n'; exit 0; }
else
  unk "upstream release check skipped (--no-network)"
fi

# ------------------------------------------------------------------------------------------------
hdr "C · STACK — is every service actually alive"

if [ -d "$APP_DIR" ]; then
  names="$(dk ps --format '{{.Names}}\t{{.Status}}' | grep '^openarchiver-' || true)"
  if [ -z "$names" ]; then
    bad "no openarchiver-* containers are running"
  else
    count="$(printf '%s\n' "$names" | grep -c .)"
    if [ "$count" -eq 5 ]; then ok "5 containers up"; else bad "expected 5 containers, found $count"; fi
    printf '%s\n' "$names" | sed 's/^/          /'
    if printf '%s' "$names" | grep -qi 'restarting\|unhealthy'; then
      bad "a container is restarting or unhealthy — see the list above"
    fi
  fi

  # The backend once died while the frontend kept serving, so the app LOOKED healthy and simply
  # could not log anyone in. Never infer the backend from the frontend.
  be="$(dk exec openarchiver-app sh -c 'command -v node >/dev/null && node -e "
const s=require(\"net\").connect({host:\"127.0.0.1\",port:4000});
s.setTimeout(4000);
const d=(v)=>{console.log(v);process.exit(0)};
s.on(\"connect\",()=>d(\"UP\"));s.on(\"error\",()=>d(\"DOWN\"));s.on(\"timeout\",()=>d(\"DOWN\"));
"' | tr -d '\r\n')"
  case "$be" in
    UP)   ok "backend is listening on :4000 (the failure that once looked like a broken login)" ;;
    DOWN) bad "THE BACKEND IS NOT LISTENING on :4000 — the UI will load but nothing will work"
          note "sudo docker compose -f $APP_DIR/docker-compose.yml logs --tail=50 open-archiver" ;;
    *)    unk "could not probe the backend from inside openarchiver-app" ;;
  esac

  app_url="$(app_base_url)"
  fe="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$app_url/" 2>/dev/null)"
  case "$fe" in
    2*|3*|401|403) ok "frontend answers at $app_url (HTTP $fe)" ;;
    *) bad "frontend not answering at $app_url (HTTP ${fe:-none})" ;;
  esac

  if [ "$(q1 'select 1')" = "1" ]; then ok "PostgreSQL reachable"; else bad "cannot query PostgreSQL in $PG"; fi
fi

# ------------------------------------------------------------------------------------------------
hdr "D · CONFIG — hardening, and the settings that decide whether a scan is found"

envget(){ sudo sed -n "s/^$1=//p" "$APP_DIR/.env" 2>/dev/null | head -1; }

if [ ! -d "$APP_DIR" ]; then
  unk "no install — config not checked"
else
  cfg="$(cd "$APP_DIR" && sudo docker compose config 2>/dev/null)"
  if [ -z "$cfg" ]; then
    unk "could not render the running compose config"
  else
    if grep -q 'MEILI_NO_ANALYTICS' <<<"$cfg"; then
      ok "Meilisearch telemetry disabled"
    else
      bad "MEILI_NO_ANALYTICS not set — Meilisearch reports home by default"
    fi
    hostips="$(sed -n 's/.*host_ip: *//p' <<<"$cfg" | tr -d '"' | tr -d ' ')"
    npub="$(grep -cE 'published:' <<<"$cfg")"
    bad_ip=""
    for ip in $hostips; do bind_ok "$ip" || bad_ip="$bad_ip $ip"; done
    if [ "${npub:-0}" -gt 0 ] && [ -z "$hostips" ]; then
      bad "$npub port(s) published with no host_ip — that means EVERY interface"
    elif [ -n "$bad_ip" ]; then
      bad "a port is published on a disallowed interface:$bad_ip (want loopback or 100.64.0.0/10)"
    else
      ok "published ports are on loopback or the tailnet ($(tr '\n' ' ' <<<"$hostips"))"
    fi
    if grep -qE "source: $ARCHIVE_ROOT(/|$)" <<<"$cfg"; then
      bad "THE ARCHIVE IS MOUNTED INTO A CONTAINER — it must never be"
    else
      ok "$ARCHIVE_ROOT is not mounted into any container"
    fi
    if grep -A3 'source: .*/import' <<<"$cfg" | grep -q 'read_only: true'; then
      ok "import/ is mounted READ-ONLY"
    else
      bad "the import mount is NOT read-only"
    fi
  fi

  st="$(envget STORAGE_TYPE)"
  if [ "$st" = "local" ]; then
    ok "STORAGE_TYPE=local (its absence silently kills every backend process)"
  else
    bad "STORAGE_TYPE is '${st:-unset}' — must be 'local'"
  fi

  del="$(envget ENABLE_DELETION)"
  if [ "$del" = "false" ]; then
    ok "ENABLE_DELETION=false — nothing in this archive gets deleted by an app"
    note "this is ALSO what blocks deleting ingestion sources in the UI. That block is the hardening"
    note "working as designed, not a bug — see openarchiver/README.md for the sanctioned way round it"
  else
    bad "ENABLE_DELETION is '${del:-unset}' — the app can delete archived mail"
  fi

  for k in ORIGIN APP_URL BODY_SIZE_LIMIT INGESTION_WORKER_CONCURRENCY PDF_PARSE_TIMEOUT_MS ALL_INCLUSIVE_ARCHIVE; do
    v="$(envget "$k")"
    if [ -n "$v" ]; then note "$(printf '%-30s %s' "$k" "$v")"; else unk "$k is unset"; fi
  done

  # THE SETTING MOST LIKELY TO LOSE THE DOCUMENT WE ARE HUNTING.
  # OCR runs at 1-3 s per page (measured). A faxed will is not one page. If this timeout applies to
  # the OCR path, a long scan can exceed it and the attachment's text never reaches the index — the
  # search then comes back empty for a document that WAS imported, which is the worst possible
  # failure here: it looks like the document is not there.
  pt="$(envget PDF_PARSE_TIMEOUT_MS)"
  if [ -n "$pt" ] && [ "$pt" -le 60000 ] 2>/dev/null; then
    bad "PDF_PARSE_TIMEOUT_MS=$pt (${pt%???}s) is too low for multi-page scanned faxes"
    note "measured OCR cost is 1-3 s PER PAGE. A 20-page fax needs 20-60 s of OCR alone."
    note "If this timeout covers the OCR path, long scans are silently indexed WITHOUT their text,"
    note "and the hunt returns nothing for a document that was imported successfully."
    note "Raise it before the real import, then prove OCR on a multi-page scan."
  elif [ -n "$pt" ]; then
    ok "PDF_PARSE_TIMEOUT_MS=$pt — enough headroom for a multi-page scan"
  fi

  if sudo grep -qiE '^(GOOGLE|MICROSOFT|AZURE|MS_)[A-Z_]*=(.+)$' "$APP_DIR/.env" 2>/dev/null; then
    bad "cloud connector credentials present in .env — the only internet-facing part"
  else
    ok "no Google/Microsoft connector credentials configured"
  fi
fi

# ------------------------------------------------------------------------------------------------
hdr "E · SECRETS — are the unregenerable keys provably off the box"

bev=""
[ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/openarchiver/backup-env.sh" ] && bev="$REPO_DIR/openarchiver/backup-env.sh"
if [ -z "$bev" ]; then
  unk "backup-env.sh not found in the checkout — cannot fingerprint the secrets"
else
  envsha="$(bash "$bev" fingerprint 2>/dev/null | sed -n 's/^  sha256: //p' | head -1)"
  if [ -z "$envsha" ]; then
    bad "could not fingerprint $APP_DIR/.env — run: bash openarchiver/backup-env.sh"
  else
    ok ".env is well-formed; digest $envsha"
    if [ -z "$BACKUP_VERIFIED" ]; then
      # This box cannot see off-box storage, so it must not pretend to know. The honest state is
      # UNKNOWN until the operator has actually run the verify and says which digest they verified.
      note "This script cannot see off-box storage, so it cannot tell you a backup exists."
      note "Verify the copy wherever it lives, then re-run preflight asserting what you verified:"
      note "  bash openarchiver/backup-env.sh verify PATH --expect $envsha"
      note "  bash openarchiver/preflight.sh --env-backup-verified $envsha"
      unk "whether a verified copy exists OFF this box (only you can establish that)"
    elif [ "$BACKUP_VERIFIED" = "$envsha" ]; then
      ok "you verified a copy of THIS exact .env off the box — the lockout gate is closed"
    else
      # The dangerous middle case: a real backup, of a file that is no longer the live one.
      bad "the .env you verified is NOT the .env now on this box — the backup is STALE"
      note "  you verified: $BACKUP_VERIFIED"
      note "  live now    : $envsha"
      note "Secrets were regenerated or edited after that backup was taken. Anything imported since"
      note "is encrypted with keys your copy does not hold. Re-fetch and re-verify before importing."
    fi
  fi
fi

# ------------------------------------------------------------------------------------------------
hdr "F · INGESTION — exactly what is in there now"

if [ "$(q1 'select 1')" != "1" ]; then
  unk "database unreachable — ingestion state unknown"
else
  total="$(q1 'select count(*) from archived_emails')"
  if [ -n "$total" ]; then ok "messages archived: $total"; else unk "could not count archived_emails"; fi

  # Discover the sources table rather than guessing its name — the schema is undocumented, and a
  # guessed table that does not exist returns empty, which reads exactly like "no sources".
  src_tbl=""
  for t in ingestion_sources ingestionsources sources; do
    [ "$(q1 "select count(*) from information_schema.tables where table_name='$t'")" = "1" ] && { src_tbl="$t"; break; }
  done
  if [ -z "$src_tbl" ]; then
    unk "could not find the ingestion-sources table (looked for ingestion_sources, sources)"
  else
    ok "ingestion sources (table $src_tbl):"
    cols="$(q "select string_agg(column_name,',') from information_schema.columns where table_name='$src_tbl'")"
    namecol="name"; grep -q '\bname\b' <<<"$cols" || namecol="$(cut -d, -f2 <<<"$cols")"
    q "select id || '  ' || coalesce($namecol::text,'?') from $src_tbl order by 1" | sed 's/^/          /'
    nsrc="$(q1 "select count(*) from $src_tbl")"
    note "total sources: ${nsrc:-?}"
    note "Everything currently stored is TEST data (synthetic fixtures + two auto-archives)."
    note "The store is DERIVED — rebuildable from the masters — so clearing it loses nothing real."
  fi

  # Duplicate state, so the merge-dedup question can be answered against a known starting point.
  idc=""
  for c in message_id messageid message_id_header; do
    [ "$(q1 "select count(*) from information_schema.columns where table_name='archived_emails' and column_name='$c'")" = "1" ] && { idc="$c"; break; }
  done
  if [ -n "$idc" ]; then
    dg="$(q1 "select count(*) from (select $idc from archived_emails where $idc is not null group by $idc having count(*)>1) t")"
    dr="$(q1 "select count(*)-count(distinct $idc) from archived_emails where $idc is not null")"
    ok "duplicate state: ${dg:-?} messages stored more than once, ${dr:-?} redundant rows"
    note "this is the BASELINE for the merge-into-existing test — record it before that import"
  else
    unk "no message-identity column found on archived_emails"
  fi
fi

if [ -d "$APP_DIR/import" ]; then
  staged="$(find "$APP_DIR/import" -maxdepth 1 -type f ! -name PROVENANCE.tsv 2>/dev/null | wc -l)"
  ok "files staged in import/: $staged"
  find "$APP_DIR/import" -maxdepth 1 -type f ! -name PROVENANCE.tsv -printf '          %10s  %f\n' 2>/dev/null | sort -k2
fi

# ------------------------------------------------------------------------------------------------
hdr "G · NETWORK — can this be reached over LAN and Tailscale, and does ORIGIN match"

ips="$(hostname -I 2>/dev/null)"
say "  hostname -I: ${ips:-none}"
routable=""
for ip in $ips; do
  case "$ip" in
    169.254.*) note "$ip  LINK-LOCAL (APIPA) — means NO DHCP lease on that interface" ;;
    127.*)     : ;;
    100.*)     note "$ip  Tailscale (CGNAT range)"; routable="$routable $ip" ;;
    *)         note "$ip  routable LAN address"; routable="$routable $ip" ;;
  esac
done

lan=""
for ip in $routable; do case "$ip" in 100.*) ;; *) lan="$ip"; break ;; esac; done
if [ -n "$lan" ]; then
  ok "a routable LAN address exists: $lan"
elif printf '%s' "$ips" | grep -q '169\.254\.'; then
  bad "the only non-loopback address is LINK-LOCAL — there is no DHCP lease, so LAN access and a"
  note "mail.<domain> DNS rewrite cannot work. Fix the network before the LAN/Tailscale step."
  note "  ip -4 addr ; ip route ; sudo dhclient -v <iface>"
else
  unk "could not determine a LAN address"
fi

if have tailscale; then
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  tstat="$(tailscale status 2>/dev/null | head -1)"
  if [ -n "$ts" ]; then ok "Tailscale up at $ts"; note "${tstat:-}"
  else bad "tailscale is installed but has no IPv4 address — it is not connected"; fi
else
  unk "tailscale is not installed on this box"
fi

# Caddy on this box is a SYSTEMD service reading /etc/caddy/Caddyfile — not a container. Looking
# only for a container reported "no Caddy found" on a box where Caddy was running fine, which is a
# false unknown: it makes a healthy component look like a gap and buries the real ones.
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
caddy_up=""
if have systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
  caddy_up="systemd service"
elif dk ps --format '{{.Names}}' | grep -q '^caddy'; then
  caddy_up="container"
fi
if [ -n "$caddy_up" ]; then
  ok "Caddy is running ($caddy_up)"
elif have systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service'; then
  bad "Caddy is installed but NOT running — nothing is fronting the apps"
  note "  sudo systemctl status caddy"
else
  unk "no Caddy found as a systemd service or a container"
fi

if sudo test -f "$CADDYFILE" 2>/dev/null || [ -f "$CADDYFILE" ]; then
  if sudo grep -qE '^\s*https?://mail\.' "$CADDYFILE" 2>/dev/null; then
    ok "a mail.<domain> route is present in $CADDYFILE"
  else
    unk "no mail.<domain> route in $CADDYFILE — wired in archive-proxy-setup.sh but not stood up yet"
  fi
else
  unk "no $CADDYFILE to read — cannot tell whether the mail route exists"
fi

origin="$(envget ORIGIN 2>/dev/null)"
# What should actually be typed into a browser. Derived from the bind, not from hope: the published
# interface and ORIGIN have to agree, and printing the single resulting URL makes a disagreement
# obvious instead of leaving it to be discovered by a form post that silently fails.
bindaddr="$(sudo sed -n 's/.*"\([0-9.]*\):[0-9]*:3000".*/\1/p' "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1)"
if [ -n "$bindaddr" ]; then
  if [ "$bindaddr" = "127.0.0.1" ]; then
    note "published on loopback — reach it via Caddy, or an SSH tunnel:"
    note "  ssh -N -L 8931:127.0.0.1:$PORT $(id -un)@$(hostname -s 2>/dev/null || hostname)"
  else
    note "published on $bindaddr — browse directly to:  http://$bindaddr:$PORT"
  fi
fi
if [ -n "$origin" ]; then
  ok "ORIGIN=$origin"
  if [ -n "$bindaddr" ] && [ "$bindaddr" != "127.0.0.1" ] && [ "$origin" != "http://$bindaddr:$PORT" ]; then
    bad "ORIGIN does not match the published address — form posts will be REJECTED"
    note "  published: http://$bindaddr:$PORT"
    note "  ORIGIN   : $origin"
    note "  fix with: bash archive-openarchiver-setup.sh --tailscale"
  fi
  case "$origin" in
    *127.0.0.1*)
      note "This matches the SSH-tunnel access pattern ONLY."
      note "If you stand up mail.<domain>, ORIGIN and APP_URL MUST be changed to match or logins"
      note "will break. That is a cutover, not an addition:"
      note "  OPENARCHIVER_URL=http://mail.home bash archive-openarchiver-setup.sh --yes"
      note "and after it, the 127.0.0.1:8931 tunnel stops being a valid origin." ;;
  esac
else
  unk "ORIGIN is unset"
fi

# ------------------------------------------------------------------------------------------------
hdr "H · BOX — headroom against the projected corpus"

if have df; then
  for p in / "$APP_DIR" /var/lib/docker "$ARCHIVE_ROOT"; do
    [ -e "$p" ] || continue
    line="$(df -Ph "$p" 2>/dev/null | awk 'NR==2{print $4" free of "$2"  ("$5" used)"}')"
    note "$(printf '%-24s %s' "$p" "$line")"
  done
  avail_g="$(df -PBG "$APP_DIR" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')"
  # Measured: storage lands at ~1.1x the PST bytes, so 61.4 GiB distinct -> ~68 GiB.
  if [ -n "$avail_g" ]; then
    if [ "$avail_g" -ge 120 ]; then
      ok "${avail_g} GiB free where the store lives — comfortable against the ~68 GiB projection"
    elif [ "$avail_g" -ge 80 ]; then
      unk "${avail_g} GiB free — above the ~68 GiB projection but with little margin"
    else
      bad "${avail_g} GiB free — below what the full corpus needs (~68 GiB measured at 1.1x)"
    fi
  else
    unk "could not read free space for $APP_DIR"
  fi
fi

if have free; then
  memav="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
  if [ -n "$memav" ]; then
    if [ "$memav" -ge 4096 ]; then ok "${memav} MiB available RAM (the stack's floor is ~4 GiB)"
    else bad "${memav} MiB available RAM — below the stack's ~4 GiB floor"; fi
  else
    unk "could not read available memory"
  fi
fi

if [ -d "$ARCHIVE_ROOT" ]; then
  ro="$(findmnt -no OPTIONS --target "$ARCHIVE_ROOT" 2>/dev/null | head -1)"
  note "$(printf '%-24s %s' "$ARCHIVE_ROOT mount opts" "${ro:-unknown}")"
fi

# ------------------------------------------------------------------------------------------------
printf '\n%s== VERDICT%s\n' "$c_b" "$c_0"
printf '  %s%d OK%s   %s%d UNKNOWN%s   %s%d BLOCKING%s\n' \
  "$c_g" "$n_ok" "$c_0" "$c_y" "$n_unk" "$c_0" "$c_r" "$n_bad" "$c_0"

if [ "${#BLOCKERS[@]}" -gt 0 ]; then
  printf '\n  %sMust be resolved before the real ingestion:%s\n' "$c_r" "$c_0"
  for b in "${BLOCKERS[@]}"; do printf '    - %s\n' "$b"; done
fi
if [ "${#UNKNOWNS[@]}" -gt 0 ]; then
  printf '\n  %sNot observed — treat as unproven, not as fine:%s\n' "$c_y" "$c_0"
  for u in "${UNKNOWNS[@]}"; do printf '    - %s\n' "$u"; done
fi

printf '\n  This script proves NOTHING about OCR coverage or egress. Those have their own gates:\n'
printf '    bash openarchiver/verify-openarchiver.sh harden\n'
printf '    bash openarchiver/verify-openarchiver.sh egress\n'
printf '    bash openarchiver/verify-openarchiver.sh staged\n'

if [ "$n_bad" -gt 0 ]; then exit 1; fi
if [ "$n_unk" -gt 0 ]; then exit 3; fi   # distinct from both pass and fail, on purpose
exit 0
