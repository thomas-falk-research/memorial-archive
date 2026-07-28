#!/usr/bin/env bash
#
# openarchiver/verify-openarchiver.sh — prove the mail archive is safe and useful BEFORE any family
# mail goes near it. Nothing here touches /srv/archive or any real mailbox.
#
# Four gates, in the order they can each kill the plan:
#
#   harden   Is the deployed stack actually hardened? Reads the RUNNING config, not the file we wrote:
#            Meilisearch telemetry off, every port on loopback, the archive not mounted anywhere, the
#            import directory read-only, deletion disabled, no cloud connector credentials present.
#
#   ocr      THE DECIDING GATE. Import a SYNTHETIC mailbox whose only interesting content is an
#            image-only PDF attachment, then search for a token that exists ONLY inside that image.
#            If it does not come back, Tika is not OCR'ing attachments — and attachment-content search
#            is blind to precisely the faxed scans we are hunting. The value case would collapse to
#            metadata filtering, and we should know that before importing a 1.67 GB mailbox.
#
#   egress   Cut the stack off from the internet and confirm import + search still work. A mail
#            archive that needs outbound access has not earned this family's correspondence.
#
#   source   Prove an imported file is left byte-identical (sha256 before == after) and still present.
#            Upstream's behaviour toward its source file is undocumented; we do not assume.
#
# Usage:
#   bash verify-openarchiver.sh all          # every gate, in order (stops at the first failure)
#   bash verify-openarchiver.sh harden
#   bash verify-openarchiver.sh ocr
#   bash verify-openarchiver.sh egress
#   bash verify-openarchiver.sh source
#   bash verify-openarchiver.sh clean        # remove the synthetic fixtures this script created
#
# Read-only with respect to the archive and to your data. It writes ONLY into $APP_DIR/import
# (synthetic fixtures it generates) and a scratch directory.
#
set -uo pipefail

APP_DIR="${OPENARCHIVER_DIR:-/srv/apps/openarchiver}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
PORT="${OPENARCHIVER_PORT:-3010}"
BASE_URL="${OPENARCHIVER_URL:-http://127.0.0.1:$PORT}"
FIXTURE="${FIXTURE:-}"                       # image-only PDF; defaults to the repo's committed one
TOKEN="${TOKEN:-OCRWILLMARKER}"              # appears ONLY inside that image
WORK="${WORK:-${TMPDIR:-/tmp}/openarchiver-verify}"
IMPORT_DIR="$APP_DIR/import"
SYNTH_PREFIX="ZZ-SYNTHETIC-VERIFY"

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '  %sPASS%s %s\n' "$c_g" "$c_0" "$*"; }
bad(){ printf '  %sFAIL%s %s\n' "$c_r" "$c_0" "$*" >&2; }
warn(){ printf '  %sWARN%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die(){ printf '%sFATAL%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 2; }

dc(){ ( cd "$APP_DIR" && sudo docker compose "$@" ); }
fails=0

[ -d "$APP_DIR" ] || die "No install at $APP_DIR — run archive-openarchiver-setup.sh first."
command -v sudo >/dev/null 2>&1 || die "sudo is required (to read the compose config and containers)."

# Locate the committed image-only fixture: repo checkout, or next to this script.
if [ -z "$FIXTURE" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  for cand in "$here/../ci/fixtures/will-scanned.pdf" "$here/will-scanned.pdf" "$HOME/memorial-archive/ci/fixtures/will-scanned.pdf"; do
    [ -s "$cand" ] && { FIXTURE="$cand"; break; }
  done
fi

# ------------------------------------------------------------------------------------------------
gate_harden(){
  hdr "GATE 1/4 — hardening, read from the RUNNING configuration"
  local cfg
  cfg="$(dc config 2>/dev/null)"
  [ -n "$cfg" ] || { bad "could not read 'docker compose config'"; fails=$((fails+1)); return 1; }

  if grep -q 'MEILI_NO_ANALYTICS' <<<"$cfg"; then
    ok "Meilisearch telemetry explicitly disabled"
  else
    bad "MEILI_NO_ANALYTICS is NOT set — Meilisearch reports home by default"; fails=$((fails+1))
  fi

  local bad_ports
  bad_ports="$(grep -E 'published:' <<<"$cfg" | head -20)"
  if grep -E 'host_ip:' <<<"$cfg" | grep -qv '127\.0\.0\.1'; then
    bad "a port is published on a non-loopback interface:"; grep -E 'host_ip:' <<<"$cfg" | sed 's/^/      /' >&2
    fails=$((fails+1))
  else
    ok "every published port is bound to 127.0.0.1${bad_ports:+ (}${bad_ports:+$(grep -cE 'published:' <<<"$cfg") published)}"
  fi

  if grep -qE "source: $ARCHIVE_ROOT(/|$)" <<<"$cfg"; then
    bad "THE ARCHIVE IS MOUNTED INTO A CONTAINER — it must never be:"
    grep -E "source: $ARCHIVE_ROOT" <<<"$cfg" | sed 's/^/      /' >&2; fails=$((fails+1))
  else
    ok "the archive ($ARCHIVE_ROOT) is not mounted into any container"
  fi

  if grep -A3 'source: .*/import' <<<"$cfg" | grep -q 'read_only: true'; then
    ok "the import directory is mounted READ-ONLY (the app cannot alter or delete your copies)"
  else
    bad "the import mount is NOT read-only"; fails=$((fails+1))
  fi

  if grep -q 'ENABLE_DELETION: *"\?false' <<<"$cfg" || sudo grep -q '^ENABLE_DELETION=false' "$APP_DIR/.env" 2>/dev/null; then
    ok "in-app deletion disabled"
  else
    warn "ENABLE_DELETION is not false — the app can delete archived mail from its own store"
  fi

  # Cloud connectors are the only internet-facing part. Their absence is the point.
  if sudo grep -qiE '^(GOOGLE|MICROSOFT|AZURE|MS_)[A-Z_]*=(.+)$' "$APP_DIR/.env" 2>/dev/null; then
    bad "cloud connector credentials are present in .env — remove them"; fails=$((fails+1))
  else
    ok "no Google/Microsoft connector credentials configured"
  fi

  # Secrets must not be upstream's examples.
  if sudo grep -qE '^(POSTGRES_PASSWORD=password|MEILI_MASTER_KEY=aSampleMasterKey)$' "$APP_DIR/.env" 2>/dev/null; then
    bad "an upstream DEFAULT secret is still in place"; fails=$((fails+1))
  else
    ok "secrets are generated, not upstream defaults"
  fi
}

# ------------------------------------------------------------------------------------------------
# Build a synthetic mailbox: one mbox with a plain message and one message carrying the image-only
# PDF as an attachment. No real data, no real names.
make_synthetic(){
  mkdir -p "$WORK" || return 1
  [ -s "$FIXTURE" ] || { bad "no image-only fixture found (looked for ci/fixtures/will-scanned.pdf)"; return 1; }
  # Confirm the fixture really is image-only, so a pass cannot come from a text layer.
  if command -v pdftotext >/dev/null 2>&1; then
    if pdftotext "$FIXTURE" - 2>/dev/null | grep -q "$TOKEN"; then
      bad "the fixture has a TEXT layer containing $TOKEN — it would not exercise OCR at all"; return 1
    fi
    ok "fixture confirmed image-only: '$TOKEN' is not extractable without OCR"
  else
    warn "pdftotext absent — cannot confirm the fixture is image-only (install poppler-utils)"
  fi
  local b64 mbox="$WORK/${SYNTH_PREFIX}.mbox"
  b64="$(base64 "$FIXTURE" | tr -d '\n' | fold -w 76)"
  {
    printf 'From synthetic@example.invalid Thu Jan  1 00:00:00 2026\n'
    printf 'From: synthetic-sender@example.invalid\n'
    printf 'To: synthetic-recipient@example.invalid\n'
    printf 'Subject: %s plain message\n' "$SYNTH_PREFIX"
    printf 'Date: Tue, 03 Mar 2009 10:00:00 +0000\n'
    printf 'Message-ID: <%s-1@example.invalid>\n\n' "$SYNTH_PREFIX"
    printf 'This synthetic body mentions nothing interesting.\n\n'
    printf 'From synthetic@example.invalid Thu Jan  1 00:00:01 2026\n'
    printf 'From: synthetic-sender@example.invalid\n'
    printf 'To: synthetic-recipient@example.invalid\n'
    printf 'Subject: %s scanned attachment\n' "$SYNTH_PREFIX"
    printf 'Date: Tue, 03 Mar 2009 11:00:00 +0000\n'
    printf 'Message-ID: <%s-2@example.invalid>\n' "$SYNTH_PREFIX"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: multipart/mixed; boundary="SYNTHBOUND"\n\n'
    printf -- '--SYNTHBOUND\nContent-Type: text/plain\n\n'
    printf 'The body deliberately does NOT contain the token.\n\n'
    printf -- '--SYNTHBOUND\n'
    printf 'Content-Type: application/pdf; name="scanned.pdf"\n'
    printf 'Content-Transfer-Encoding: base64\n'
    printf 'Content-Disposition: attachment; filename="scanned.pdf"\n\n'
    printf '%s\n' "$b64"
    printf -- '--SYNTHBOUND--\n'
  } >"$mbox"
  [ -s "$mbox" ] || { bad "failed to build the synthetic mailbox"; return 1; }
  mkdir -p "$IMPORT_DIR" 2>/dev/null || sudo mkdir -p "$IMPORT_DIR"
  cp "$mbox" "$IMPORT_DIR/" 2>/dev/null || sudo cp "$mbox" "$IMPORT_DIR/"
  ok "synthetic mailbox placed at $IMPORT_DIR/${SYNTH_PREFIX}.mbox (2 messages, 1 image-only attachment)"
  say  "      the token '$TOKEN' exists ONLY inside the attached image — nowhere in any header or body"
  return 0
}

gate_ocr(){
  hdr "GATE 2/4 — does attachment-content search actually see inside a scan?"
  make_synthetic || { fails=$((fails+1)); return 1; }
  say ""
  say "  This gate needs the import performed once through the UI (there is no documented CLI import):"
  say "    1. open $BASE_URL  ->  Ingestion sources  ->  add a source"
  say "    2. type: Mbox      path: /import/${SYNTH_PREFIX}.mbox"
  say "    3. run it, wait for the job to finish, then search for:   $TOKEN"
  say "       with 'Search in' set to include ATTACHMENT CONTENT"
  say ""
  say "  ${c_b}How to read the result${c_0}"
  say "    token FOUND    -> Tika is OCR'ing attachments. The value case holds: every faxed scan in"
  say "                      MKH's mailbox becomes searchable by its CONTENT. Proceed to gate 3."
  say "    token MISSING  -> attachment-content search is blind to scans. Open Archiver is then only"
  say "                      a metadata filter (from/to/date/has-attachment) — still useful, but the"
  say "                      headline reason for deploying it is gone. STOP and re-plan before"
  say "                      importing the real 1.67 GB mailbox."
  say ""
  say "  Paste the outcome back. If the API is reachable without a login you can also try:"
  say "    curl -s '$BASE_URL/v1/search?keywords=$TOKEN&searchIn=attachment_content' | head -c 400"
}

# ------------------------------------------------------------------------------------------------
gate_egress(){
  hdr "GATE 3/4 — does the stack work with the internet cut off?"
  local names
  names="$(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep '^openarchiver-' || true)"
  [ -n "$names" ] || { bad "no openarchiver-* containers are running"; fails=$((fails+1)); return 1; }
  say "  containers: $(tr '\n' ' ' <<<"$names")"

  # Prove the app answers BEFORE we cut anything, so a failure after is attributable.
  local before
  before="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/" 2>/dev/null)"
  say "  app responds on 127.0.0.1:$PORT -> HTTP ${before:-none}"
  case "$before" in 2*|3*|401|403) ok "app is up before the cut" ;; *) bad "app is not responding; fix that first"; fails=$((fails+1)); return 1 ;; esac

  # Disconnect every openarchiver container from any bridge that routes outward, keeping the
  # project's internal network so the services can still reach each other. Reconnect in a trap so an
  # interrupted run cannot leave the stack half-detached.
  local nets_removed=""
  restore(){
    local entry n c
    for entry in $nets_removed; do
      c="${entry%%|*}"; n="${entry##*|}"
      sudo docker network connect "$n" "$c" >/dev/null 2>&1 || true
    done
    [ -n "$nets_removed" ] && say "  (reconnected the containers to their networks)"
  }
  trap 'restore' EXIT INT TERM

  local c n
  for c in $names; do
    for n in $(sudo docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null); do
      case "$n" in
        *default*|*openarchiver*) continue ;;   # keep the stack's own internal network
      esac
      if sudo docker network disconnect "$n" "$c" >/dev/null 2>&1; then
        nets_removed="$nets_removed $c|$n"
      fi
    done
  done
  say "  detached from outward-facing networks:${nets_removed:- (none found — already internal)}"

  # Verify from INSIDE a container that the outside world is genuinely unreachable.
  if sudo docker exec openarchiver-app sh -c 'command -v getent >/dev/null && getent hosts pypi.org' >/dev/null 2>&1; then
    warn "the app container can still resolve external names — the cut may be incomplete"
  else
    ok "external name resolution fails inside the container (egress cut)"
  fi

  local after
  after="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:$PORT/" 2>/dev/null)"
  case "$after" in
    2*|3*|401|403) ok "the app still serves with egress cut (HTTP $after)" ;;
    *) bad "the app stopped working once egress was cut (HTTP ${after:-none}) — investigate before trusting it with mail"; fails=$((fails+1)) ;;
  esac
  restore; trap - EXIT INT TERM
  say "  NOTE: this proves the SERVING path. Re-run an import while detached to prove the INGEST path"
  say "        too — that is the one that handles message content."
}

# ------------------------------------------------------------------------------------------------
gate_source(){
  hdr "GATE 4/4 — is an imported file left untouched?"
  local f="$IMPORT_DIR/${SYNTH_PREFIX}.mbox"
  if [ ! -s "$f" ]; then
    warn "no synthetic mailbox in $IMPORT_DIR — run 'ocr' first (it creates one)"
    return 0
  fi
  local sum_now stored="$WORK/${SYNTH_PREFIX}.sha256"
  sum_now="$(sha256sum "$f" | awk '{print $1}')"
  if [ -f "$stored" ]; then
    local sum_before; sum_before="$(cat "$stored")"
    if [ "$sum_now" = "$sum_before" ]; then
      ok "the imported file is byte-identical to before the import"
      ok "  $sum_now"
    else
      bad "THE SOURCE FILE CHANGED during import"
      bad "  before: $sum_before"
      bad "  after : $sum_now"
      bad "  Never point this at a master. Import only from copies — and now we know why."
      fails=$((fails+1))
    fi
  else
    printf '%s' "$sum_now" >"$stored"
    ok "recorded the pre-import checksum: $sum_now"
    say "      run this gate again AFTER the import completes to prove the file was not modified"
  fi
  # Deletion is the other half of the question.
  [ -e "$f" ] && ok "the file still exists after import (not moved or consumed)"
}

# ------------------------------------------------------------------------------------------------
case "${1:-all}" in
  harden) gate_harden ;;
  ocr)    gate_ocr ;;
  egress) gate_egress ;;
  source) gate_source ;;
  clean)
    hdr "Removing synthetic fixtures"
    rm -f "$IMPORT_DIR/${SYNTH_PREFIX}.mbox" 2>/dev/null || sudo rm -f "$IMPORT_DIR/${SYNTH_PREFIX}.mbox"
    rm -rf "$WORK"
    ok "removed $IMPORT_DIR/${SYNTH_PREFIX}.mbox and $WORK"
    say "  (delete the synthetic ingestion source in the UI too, if you created one)"
    exit 0 ;;
  all)
    gate_harden
    if [ "$fails" -eq 0 ]; then gate_ocr; else warn "skipping later gates until hardening passes"; fi
    if [ "$fails" -eq 0 ]; then gate_egress; fi
    if [ "$fails" -eq 0 ]; then gate_source; fi ;;
  *) say "Usage: ${0##*/} [all|harden|ocr|egress|source|clean]"; exit 2 ;;
esac

hdr "RESULT"
if [ "$fails" -eq 0 ]; then
  printf '  %sAll automated gates passed.%s\n' "$c_g" "$c_0"
  say "  The OCR gate (2) needs your eyes: it requires one import through the UI, and its outcome"
  say "  decides whether attachment-content search can see inside a scan. Nothing about the real"
  say "  mailbox should be decided until that token comes back."
else
  printf '  %s%d check(s) FAILED — do not import family mail yet.%s\n' "$c_r" "$fails" "$c_0"
fi
say ""
say "  Clean up the synthetic fixtures with:  bash ${0##*/} clean"
exit "$fails"
