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
BASE_URL=""   # resolved from the deployed compose once APP_DIR is known (see app_base_url)
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

fails=0

[ -d "$APP_DIR" ] || die "No install at $APP_DIR — run archive-openarchiver-setup.sh first."
command -v sudo >/dev/null 2>&1 || die "sudo is required (to read the compose config and containers)."
BASE_URL="${OPENARCHIVER_URL:-$(app_base_url)}"

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

  local hostips npub bad_ip="" ip
  hostips="$(sed -n 's/.*host_ip: *//p' <<<"$cfg" | tr -d '"' | tr -d ' ')"
  npub="$(grep -cE 'published:' <<<"$cfg")"
  if [ "${npub:-0}" -gt 0 ] && [ -z "$hostips" ]; then
    bad "$npub port(s) published with no host_ip — that means EVERY interface"
    fails=$((fails+1))
  else
    for ip in $hostips; do bind_ok "$ip" || bad_ip="$bad_ip $ip"; done
    if [ -n "$bad_ip" ]; then
      bad "a port is published on a disallowed interface:$bad_ip"
      bad "  allowed: 127.0.0.1, or this host's Tailscale address in 100.64.0.0/10"
      fails=$((fails+1))
    else
      ok "every published port is on loopback or the tailnet ($(tr '\n' ' ' <<<"$hostips"))"
    fi
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
  # v0.6.0 added a THIRD upstream default: the compose now defaults REDIS_PASSWORD to
  # 'defaultredispassword' so Valkey starts without one. A default that makes the stack boot is
  # exactly the kind that survives into production unnoticed.
  if sudo grep -qE '^(POSTGRES_PASSWORD=password|MEILI_MASTER_KEY=aSampleMasterKey|REDIS_PASSWORD=defaultredispassword)$' "$APP_DIR/.env" 2>/dev/null; then
    bad "an upstream DEFAULT secret is still in place"; fails=$((fails+1))
  else
    ok "secrets are generated, not upstream defaults"
  fi
}

# ------------------------------------------------------------------------------------------------
# The formats the estate documents actually arrive in.
#
# The original gate proved ONE thing: attachment-content search sees inside an image-only PDF. That
# is not the same as proving it sees the documents we are hunting. Those are `FaxImage.tif`,
# `image001.gif` and `SKM_*.pdf` — and a TIFF is not a PDF. Different container, different decoder
# path inside Tika, and a fax TIFF is usually MULTI-PAGE Group 4 bilevel, the least PDF-like image
# in common use. A PDF pass generalises to a TIFF only by assumption, and assumption is what this
# project does not do.
#
# So: one attachment per format, each with its OWN token, reported separately. If TIFF comes back
# blind while PDF works, that has to be visible as a partial failure rather than averaged away.
#
# fixture-file : mime-type : filename-in-mail : token
OCR_FORMATS="
will-scanned.pdf:application/pdf:scanned.pdf:OCRWILLMARKER
will-scanned.tif:image/tiff:FaxImage.tif:OCRTIFFMARKER
will-scanned-fax.tif:image/tiff:FaxImage-3page.tif:OCRFAXPAGETHREE
will-scanned.gif:image/gif:image001.gif:OCRGIFMARKER
will-scanned-long.pdf:application/pdf:SKM_C224e_25page.pdf:OCRLASTPAGEMARKER
"

fixture_dir(){
  local here; here="$(cd "$(dirname "$0")" && pwd)"
  for d in "$here/../ci/fixtures" "$here/fixtures" "$HOME/memorial-archive/ci/fixtures"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# emit_part <file> <mime> <name> — one base64 MIME attachment part.
emit_part(){
  local f="$1" mime="$2" name="$3"
  printf -- '--SYNTHBOUND\n'
  printf 'Content-Type: %s; name="%s"\n' "$mime" "$name"
  printf 'Content-Transfer-Encoding: base64\n'
  printf 'Content-Disposition: attachment; filename="%s"\n\n' "$name"
  base64 "$f" | tr -d '\n' | fold -w 76
  printf '\n'
}

make_synthetic(){
  mkdir -p "$WORK" || return 1
  local fdir; fdir="$(fixture_dir)" || { bad "no ci/fixtures directory found"; return 1; }

  # Which formats do we actually have fixtures for? Missing ones are reported, never silently
  # dropped — a gate that quietly tests fewer formats than it claims is the failure mode here.
  local have_any=0 line file mime name tok missing=""
  ATTACHED=""
  for line in $OCR_FORMATS; do
    file="${line%%:*}"; rest="${line#*:}"
    mime="${rest%%:*}"; rest="${rest#*:}"
    name="${rest%%:*}"; tok="${rest#*:}"
    if [ -s "$fdir/$file" ]; then
      have_any=1
      ATTACHED="$ATTACHED$file:$mime:$name:$tok "
    else
      missing="$missing $file"
    fi
  done
  if [ "$have_any" -eq 0 ]; then
    bad "no OCR fixtures found in $fdir — regenerate them with: bash ci/make-fixtures.sh"
    return 1
  fi
  if [ -n "$missing" ]; then
    warn "these format fixtures are absent, so those formats are NOT being tested:$missing"
    warn "  regenerate them on a box with ImageMagick: bash ci/make-fixtures.sh"
    warn "  until then, a PASS below says nothing about the missing formats."
  fi

  # Any fixture with a text layer would pass without OCR ever running. Check the PDFs.
  if command -v pdftotext >/dev/null 2>&1; then
    for line in $ATTACHED; do
      file="${line%%:*}"; tok="${line##*:}"
      case "$file" in *.pdf)
        if pdftotext "$fdir/$file" - 2>/dev/null | grep -q "$tok"; then
          bad "$file has a TEXT layer containing $tok — it would not exercise OCR at all"; return 1
        fi ;;
      esac
    done
    ok "PDF fixtures confirmed image-only — their tokens are not extractable without OCR"
  else
    warn "pdftotext absent — cannot confirm the PDF fixtures are image-only (install poppler-utils)"
  fi

  local mbox="$WORK/${SYNTH_PREFIX}.mbox" n=0
  {
    printf 'From synthetic@example.invalid Thu Jan  1 00:00:00 2026\n'
    printf 'From: synthetic-sender@example.invalid\n'
    printf 'To: synthetic-recipient@example.invalid\n'
    printf 'Subject: %s plain message\n' "$SYNTH_PREFIX"
    printf 'Date: Tue, 03 Mar 2009 10:00:00 +0000\n'
    printf 'Message-ID: <%s-1@example.invalid>\n\n' "$SYNTH_PREFIX"
    printf 'This synthetic body mentions nothing interesting.\n\n'
    # One message PER FORMAT. Separate messages, not one message with five attachments: a single
    # message would let one failed extraction take the others down with it, and the result view
    # would not say which attachment the hit came from.
    for line in $ATTACHED; do
      file="${line%%:*}"; rest="${line#*:}"
      mime="${rest%%:*}"; rest="${rest#*:}"
      name="${rest%%:*}"; tok="${rest#*:}"
      n=$((n+1))
      printf 'From synthetic@example.invalid Thu Jan  1 00:00:0%d 2026\n' "$n"
      printf 'From: synthetic-sender@example.invalid\n'
      printf 'To: synthetic-recipient@example.invalid\n'
      printf 'Subject: %s scanned attachment %s\n' "$SYNTH_PREFIX" "$name"
      printf 'Date: Tue, 03 Mar 2009 1%d:00:00 +0000\n' "$n"
      printf 'Message-ID: <%s-att%d@example.invalid>\n' "$SYNTH_PREFIX" "$n"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: multipart/mixed; boundary="SYNTHBOUND"\n\n'
      printf -- '--SYNTHBOUND\nContent-Type: text/plain\n\n'
      printf 'The body deliberately does NOT contain the token.\n\n'
      emit_part "$fdir/$file" "$mime" "$name"
      printf -- '--SYNTHBOUND--\n\n'
    done
  } >"$mbox"
  [ -s "$mbox" ] || { bad "failed to build the synthetic mailbox"; return 1; }

  # Prove the tokens are not in the mbox as plaintext. Base64 hides them, but this is the assertion
  # that makes a later hit attributable to OCR and nothing else — so it is checked, not assumed.
  for line in $ATTACHED; do
    tok="${line##*:}"
    if grep -qF "$tok" "$mbox"; then
      bad "token $tok appears as PLAINTEXT in the synthetic mailbox — a hit would prove nothing"
      return 1
    fi
  done
  ok "no token appears in the mailbox as plaintext — only OCR can surface them"

  mkdir -p "$IMPORT_DIR" 2>/dev/null || sudo mkdir -p "$IMPORT_DIR"
  cp "$mbox" "$IMPORT_DIR/" 2>/dev/null || sudo cp "$mbox" "$IMPORT_DIR/"
  ok "synthetic mailbox placed at $IMPORT_DIR/${SYNTH_PREFIX}.mbox"
  return 0
}

gate_ocr(){
  hdr "GATE 2/4 — does attachment-content search see inside EVERY format we are hunting?"
  make_synthetic || { fails=$((fails+1)); return 1; }
  say ""
  say "  Import it once through the UI (there is no documented CLI import):"
  say "    1. open $BASE_URL  ->  Ingestion sources  ->  add a source"
  say "    2. type: Mbox      path: /import/${SYNTH_PREFIX}.mbox"
  say "       Preserve Original File = CHECKED"
  say "    3. wait for the job to FINISH, then search each token below with 'Search in' set to"
  say "       include ATTACHMENT CONTENT"
  say ""
  say "  ${c_b}Search each of these and record FOUND or MISSING for every line${c_0}"
  say ""
  # Only explain the formats actually attached. Printing guidance for a token that is not in the
  # mailbox would invite someone to search for it, not find it, and read that as a blocker.
  local line file rest mime name tok
  for line in $ATTACHED; do
    file="${line%%:*}"; rest="${line#*:}"
    mime="${rest%%:*}"; rest="${rest#*:}"
    name="${rest%%:*}"; tok="${rest#*:}"
    printf '    %-18s in %-24s (%s)\n' "$tok" "$name" "$file"
    case "$tok" in
      OCRWILLMARKER)
        say "        image-only PDF. Proven once already; a miss here is a REGRESSION — something"
        say "        changed in Tika or in the configuration." ;;
      OCRTIFFMARKER)
        say "        single-page TIFF, the FaxImage.tif shape. If this is missing, the faxed estate"
        say "        documents are invisible to content search however well the PDF path works."
        say "        This is the format the hunt actually depends on." ;;
      OCRFAXPAGETHREE)
        say "        page 3 of a 3-page Group 4 fax TIFF. Missing while OCRTIFFMARKER is found means"
        say "        only the FIRST page of each multi-page fax is indexed — and a will is not one page." ;;
      OCRGIFMARKER)
        say "        the image001.gif shape." ;;
      OCRLASTPAGEMARKER)
        say "        the last page of a 25-page image-only PDF. Missing while OCRWILLMARKER is found"
        say "        means long scans are truncated or timing out, and the document is indexed with no"
        say "        text and NO ERROR. Raise PDF_PARSE_TIMEOUT_MS and Tika's OCR timeout, then re-run." ;;
    esac
    say ""
  done
  say "    ${c_r}Any MISSING line is a blocker for the real import${c_0} — importing 61 GiB against a"
  say "    format the index cannot read produces confident, empty searches over documents that"
  say "    are actually there. That is worse than knowing it does not work."
  say ""
  say "  If the API is reachable without a login, each token can be checked directly:"
  say "    curl -s '$BASE_URL/v1/search?keywords=OCRTIFFMARKER&searchIn=attachment_content' | head -c 400"
}

# ------------------------------------------------------------------------------------------------
gate_egress(){
  hdr "GATE 3/4 — does the stack work with the internet actually cut off?"
  # WHY THIS IS NOT JUST `docker network disconnect`: every Docker BRIDGE network provides outbound
  # NAT through the host. Detaching the containers from the shared 'memorial' bridge while keeping the
  # project's own bridge (so the services can still reach each other) leaves egress fully intact — the
  # first version of this gate did exactly that and would have reported PASS on an uncut stack.
  #
  # The real cut is `internal: true` on the project network, which removes its gateway. We apply it as
  # a temporary compose override, prove from INSIDE the network that the outside is unreachable, then
  # remove the override. A cut we cannot prove is not evidence, so failing to cut FAILS the gate.
  local names probe_img="${OA_PG_IMAGE:-postgres:17-alpine}"
  names="$(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep '^openarchiver-' || true)"
  [ -n "$names" ] || { bad "no openarchiver-* containers are running"; fails=$((fails+1)); return 1; }
  say "  containers: $(tr '\n' ' ' <<<"$names")"

  local before
  say "  probing the app at $BASE_URL (read from the deployed compose, not assumed)"
  before="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/" 2>/dev/null)"
  case "$before" in
    2*|3*|401|403) ok "app responds before the cut (HTTP $before)" ;;
    *) bad "app is not responding at $BASE_URL (HTTP ${before:-none}) — fix that before testing egress"
       bad "  if the bind was changed, the app may be on a different address than this probe used:"
       bad "  $(sudo grep -oE '"[0-9.]+:[0-9]+:3000"' "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1)"
       fails=$((fails+1)); return 1 ;;
  esac

  local net override="$APP_DIR/docker-compose.egress-test.yml"
  net="$(sudo docker inspect openarchiver-app --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E 'openarchiver|default' | head -1)"
  [ -n "$net" ] || { bad "could not determine the project network"; fails=$((fails+1)); return 1; }
  say "  project network: $net"

  # egress_open <network> — 0 if the outside world is reachable from inside that network. Tests a raw
  # IP as well as DNS, so a DNS-only failure cannot masquerade as a blocked network.
  egress_open(){
    sudo docker run --rm --network "$1" "$probe_img" sh -c \
      'wget -T 4 -q -O /dev/null http://1.1.1.1/ 2>/dev/null && exit 0
       getent hosts one.one.one.one >/dev/null 2>&1 && exit 0
       exit 1' >/dev/null 2>&1
  }

  # Baseline: egress must be OPEN now, or the test proves nothing later.
  if egress_open "$net"; then
    say "  baseline: the outside world IS reachable from $net (as expected)"
  else
    warn "the outside world is ALREADY unreachable from $net — cannot demonstrate a change."
    warn "That may be fine (restrictive host firewall), but this gate cannot prove anything. Treating as inconclusive."
    fails=$((fails+1)); return 1
  fi

  restore(){
    sudo rm -f "$override" 2>/dev/null
    ( cd "$APP_DIR" && sudo docker compose up -d >/dev/null 2>&1 )
    say "  (restored the normal network configuration)"
  }
  trap 'restore' EXIT INT TERM

  say "  applying a temporary override: network '$net' -> internal: true (containers will recreate)"
  sudo tee "$override" >/dev/null <<'OVR'
# TEMPORARY — written by verify-openarchiver.sh, removed when the gate finishes.
networks:
  default:
    internal: true
OVR
  if ! ( cd "$APP_DIR" && sudo docker compose -f docker-compose.yml -f docker-compose.egress-test.yml up -d >/dev/null 2>&1 ); then
    bad "could not apply the egress-test override"; fails=$((fails+1)); restore; trap - EXIT INT TERM; return 1
  fi
  # The app ALSO joins the shared 'memorial' bridge, which would keep its egress alive regardless of
  # what we did to the project network. Detach it, then VERIFY the detachment — a best-effort
  # `|| true` here would leave the gate certifying a container that still had a way out.
  sudo docker network disconnect memorial openarchiver-app >/dev/null 2>&1 \
    && say "  detached openarchiver-app from the shared 'memorial' bridge"
  local still_on
  still_on="$(sudo docker inspect openarchiver-app \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -v "^$" | grep -vF "$net" || true)"
  if [ -n "$still_on" ]; then
    bad "openarchiver-app is still attached to a network outside the cut: $(tr '\n' ' ' <<<"$still_on")"
    bad "  It may retain outbound access through it, so this gate cannot certify anything."
    fails=$((fails+1)); restore; trap - EXIT INT TERM; return 1
  fi
  ok "openarchiver-app is attached ONLY to the internal network"

  # Ask the APP CONTAINER ITSELF, not a sibling. A probe container on the project network proves that
  # NETWORK has no route out; it says nothing about a container that also sits on another bridge.
  # The app is a Node service, so node is guaranteed present — no extra tooling needed.
  local app_egress
  app_egress="$(sudo docker exec openarchiver-app node -e '
const s=require("net").connect({host:"1.1.1.1",port:443});
s.setTimeout(5000);
const done=(v)=>{console.log(v);process.exit(0)};
s.on("connect",()=>done("OPEN"));
s.on("error",()=>done("BLOCKED"));
s.on("timeout",()=>done("BLOCKED"));
' 2>/dev/null | tr -d '\r\n')"
  case "$app_egress" in
    BLOCKED) ok "the APP CONTAINER itself cannot open an outbound connection" ;;
    OPEN)    bad "THE APP CONTAINER CAN STILL REACH THE INTERNET — the cut did not hold."
             bad "  Do not treat the stack as verified offline."
             fails=$((fails+1)); restore; trap - EXIT INT TERM; return 1 ;;
    *)       warn "could not test egress from inside the app container (node probe returned '${app_egress:-nothing}')"
             warn "falling back to the network-level probe, which is weaker" ;;
  esac

  if egress_open "$net"; then
    bad "EGRESS IS STILL OPEN after the cut — this gate cannot certify anything."
    bad "  Do not treat the stack as verified offline. Investigate before importing mail."
    fails=$((fails+1)); restore; trap - EXIT INT TERM; return 1
  fi
  ok "the stack's network has no route out either (raw IP and DNS both fail)"

  # Check the app FROM INSIDE the network, not from the host.
  #
  # `internal: true` does not only remove the gateway — it also stops Docker publishing ports to the
  # host. So a host-side curl returning 000 after the cut is the EXPECTED consequence of the method,
  # not evidence the app died. Testing from a sibling container on the same network separates the two
  # questions: the app is still addressable there, while egress is genuinely gone.
  say "  (the published port is intentionally unreachable from the host under internal:true —"
  say "   checking the app from a sibling container on the same network instead)"
  sleep 5   # let the app finish restarting after the recreate
  #
  # Read the RAW status line over a socket rather than using wget.
  #
  # wget follows redirects by default. This app answers / with a 307 to its ORIGIN, and under
  # `internal: true` that address is deliberately unreachable — so wget chased the redirect off the
  # cut network, failed, and printed nothing, which the gate reported as "the app stopped
  # answering". The app was serving perfectly. The earlier egress probe only ever proved wget
  # FAILS, so a successful fetch had never been exercised in this image.
  #
  # A one-line HTTP/1.0 request over nc answers the actual question — is something serving on
  # :3000 — without interpreting or following anything.
  # Probe with NODE, from the app's own image, run as a SEPARATE container on the cut network.
  #
  # Third client, third behaviour. busybox wget followed the app's 307 off the unreachable network.
  # busybox nc in postgres:17-alpine returned nothing at all. Guessing at a fourth would be the same
  # mistake again, so this uses the one HTTP client whose behaviour here is known and guaranteed
  # present: the app image ships node, and node's http.get does NOT follow redirects.
  #
  # It is still a genuine network probe — a separate container reaching the app over the cut
  # network — not the app asked about itself.
  #
  # Every method reports what it actually returned, so a future failure names its cause instead of
  # producing another silent "no response".
  local app_img status="" i=0 how=""
  app_img="$(sudo docker inspect openarchiver-app --format '{{.Config.Image}}' 2>/dev/null)"
  say "  probe: node http.get from a sibling container using ${app_img:-the app image}"

  probe_once(){
    local out
    if [ -n "$app_img" ]; then
      out="$(sudo docker run --rm --entrypoint node --network "$net" "$app_img" -e '
const http = require("http");
const req = http.get({host:"openarchiver-app", port:3000, path:"/", timeout:8000}, r => {
  console.log(r.statusCode); r.destroy(); process.exit(0);
});
req.on("timeout", () => { console.log("TIMEOUT"); req.destroy(); process.exit(0); });
req.on("error", e => { console.log("ERR:" + e.code); process.exit(0); });
' 2>/dev/null | tr -d "\r\n")"
      if [ -n "$out" ]; then how="node"; printf '%s' "$out"; return 0; fi
    fi
    # Fallback: raw socket via the probe image, for the case where the app image lacks node.
    out="$(sudo docker run --rm --network "$net" "$probe_img" sh -c \
      'command -v nc >/dev/null 2>&1 || { echo NO_NC; exit 0; }
       printf "GET / HTTP/1.0\r\nHost: openarchiver-app\r\nConnection: close\r\n\r\n" \
         | nc -w 8 openarchiver-app 3000 2>/dev/null | head -1' 2>/dev/null \
      | tr -d "\r")"
    how="nc"; printf '%s' "$out"
  }

  while [ "$i" -lt 8 ]; do
    raw="$(probe_once)"
    status="$(printf '%s' "$raw" | grep -oE '^[0-9]{3}$' || printf '%s' "$raw" | grep -oE 'HTTP/1\.[01] [0-9]{3}' | awk '{print $2}')"
    case "$status" in 2*|3*|401|403) break ;; esac
    [ -n "$raw" ] && say "  (attempt $((i+1)) via $how returned: $raw)"
    i=$((i+1)); sleep 5
  done
  case "$status" in
    2*|3*|401|403) ok "the app still serves with egress genuinely cut (HTTP $status, from inside the network)" ;;
    *)
       # Distinguish "the app died" from "the probe could not ask". They need different fixes, and
       # guessing between them is what cost a cycle here.
       local state
       state="$(sudo docker inspect openarchiver-app --format '{{.State.Status}}' 2>/dev/null)"
       if [ "$state" = "running" ]; then
         bad "no HTTP status from openarchiver-app, but the container IS running (state: $state)"
         bad "  last probe (via ${how:-none}) returned: '${raw:-nothing}'"
         bad "  That points at the PROBE, not the app. Check by hand — the cut is already restored:"
         bad "    sudo docker run --rm --entrypoint node --network $net ${app_img:-IMAGE} \\"
         bad "      -e 'require(\"http\").get({host:\"openarchiver-app\",port:3000},r=>console.log(r.statusCode))'"
       else
         bad "the app stopped answering once egress was really cut (container state: ${state:-unknown})"
         bad "  A mail archive that needs outbound access has not earned this family's correspondence."
         bad "  Check what it was reaching for:  sudo docker compose logs --tail=50 open-archiver"
       fi
       fails=$((fails+1)) ;;
  esac

  restore; trap - EXIT INT TERM
  say "  NOTE: this proves the SERVING path. To prove INGEST too, re-run an import while the override"
  say "        is applied — that is the path that handles message content."
}

# ------------------------------------------------------------------------------------------------
gate_source(){
  hdr "GATE 4/4 — is an imported file left untouched?"
  mkdir -p "$WORK" 2>/dev/null   # without this the baseline write fails SILENTLY and every run
                                 # re-records instead of comparing — i.e. never actually checks
  local f="$IMPORT_DIR/${SYNTH_PREFIX}.mbox"
  local stored="$WORK/${SYNTH_PREFIX}.sha256"

  # A missing file means opposite things depending on whether we have a baseline. With one, the file
  # was moved or consumed BY THE IMPORT — the single most dangerous outcome this gate exists to catch.
  if [ ! -s "$f" ]; then
    if [ -f "$stored" ]; then
      bad "THE SOURCE FILE IS GONE after import — it was moved or consumed, not just read."
      bad "  Expected: $f"
      bad "  A master fed to this app would have been destroyed. Import only from copies."
      fails=$((fails+1))
    else
      warn "no synthetic mailbox in $IMPORT_DIR and no baseline recorded — run 'ocr' first (it creates one)"
    fi
    return 0
  fi

  local sum_now; sum_now="$(sha256sum "$f" | awk '{print $1}')"
  if [ -f "$stored" ]; then
    local sum_before; sum_before="$(cat "$stored")"
    if [ "$sum_now" = "$sum_before" ]; then
      ok "the imported file is byte-identical to before the import"
      ok "  $sum_now"
      ok "the file still exists after import (not moved or consumed)"
    else
      bad "THE SOURCE FILE CHANGED during import"
      bad "  before: $sum_before"
      bad "  after : $sum_now"
      bad "  Never point this at a master. Import only from copies — and now we know why."
      fails=$((fails+1))
    fi
  else
    if printf '%s' "$sum_now" >"$stored"; then
      ok "recorded the pre-import checksum: $sum_now"
      say "      baseline only — nothing is proven yet. Run this gate AGAIN after the import; the"
      say "      comparison is what answers whether the file was modified or removed."
    else
      bad "could not write the baseline to $stored — this gate cannot verify anything"
      fails=$((fails+1))
    fi
  fi
}

# ------------------------------------------------------------------------------------------------
# gate_staged — verify EVERY file staged by stage-mailbox.sh against its recorded checksum.
# gate_source only knows the synthetic fixture by name; this covers the real mailboxes, which is
# where being wrong actually costs something. Run it after any import.
gate_staged(){
  hdr "STAGED FILES — still present, still byte-identical to what was staged?"
  local manifest="$IMPORT_DIR/PROVENANCE.tsv"
  if [ ! -s "$manifest" ]; then
    warn "no $manifest — nothing has been staged with stage-mailbox.sh yet"
    return 0
  fi
  local n=0 bad_n=0 sha name path
  while IFS=$'\t' read -r _ts sha _bytes name path; do
    [ "$_ts" = "staged_utc" ] && continue      # header
    [ -n "$name" ] || continue
    n=$((n+1))
    local f="$IMPORT_DIR/$name"
    if [ ! -e "$f" ]; then
      bad "GONE: $name was staged but is no longer in $IMPORT_DIR"
      bad "  the app moved or consumed it — its master is still at: ${path:-unknown}"
      bad_n=$((bad_n+1)); fails=$((fails+1)); continue
    fi
    local now; now="$(sha256sum "$f" | awk '{print $1}')"
    if [ "$now" = "$sha" ]; then
      ok "unchanged: $name"
    else
      bad "MODIFIED: $name"
      bad "  staged: $sha"
      bad "  now   : $now"
      bad "  master (untouched, re-stage from here): ${path:-unknown}"
      bad_n=$((bad_n+1)); fails=$((fails+1))
    fi
  done < "$manifest"
  [ "$n" -eq 0 ] && { warn "manifest has no entries"; return 0; }
  if [ "$bad_n" -eq 0 ]; then
    ok "all $n staged file(s) intact — the app reads its imports and leaves them alone"
  else
    bad "$bad_n of $n staged file(s) changed or vanished. NEVER stage a master; re-copy from the archive."
  fi
}

# ------------------------------------------------------------------------------------------------
case "${1:-all}" in
  harden) gate_harden ;;
  ocr)    gate_ocr ;;
  egress) gate_egress ;;
  source) gate_source ;;
  staged) gate_staged ;;
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
    if [ "$fails" -eq 0 ]; then gate_source; fi
    if [ "$fails" -eq 0 ]; then gate_staged; fi ;;
  *) say "Usage: ${0##*/} [all|harden|ocr|egress|source|staged|clean]"; exit 2 ;;
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
