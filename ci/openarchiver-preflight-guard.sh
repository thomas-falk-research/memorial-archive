#!/usr/bin/env bash
#
# ci/openarchiver-preflight-guard.sh — drill openarchiver/preflight.sh against a STUBBED box.
#
# preflight.sh is the script we will trust to say "archive-pc is ready for the real ingestion".
# A readiness check that reports ready no matter what the box looks like is worse than no check at
# all, because it manufactures confidence. So every condition it claims to detect is planted here
# and the script must BLOCK on it, naming the reason:
#
#   the backend dead behind a healthy-looking frontend · a missing container · Meilisearch telemetry
#   back on · the archive mounted into a container · a writable import mount · STORAGE_TYPE dropped ·
#   deletion re-enabled · an OCR timeout too short for a multi-page fax · image drift between compose
#   and the running container · a link-local-only address · too little disk · too little RAM · cloud
#   connector credentials · and a .env backup that is real but STALE.
#
# Everything is stubbed: docker, sudo, curl, hostname, tailscale, df, free, findmnt. No real box, no
# real containers, no network. The repo section runs against a scratch git repo so a developer's
# dirty working tree cannot influence the result.
#
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(repo_root)"
TOOL="$ROOT/openarchiver/preflight.sh"
[ -f "$TOOL" ] || { bad "missing $TOOL — nothing to drill"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"; STATE="$WORK/state"; APP="$WORK/app"; FAKEREPO="$WORK/repo"
mkdir -p "$STUBS" "$STATE" "$APP/import" "$FAKEREPO/openarchiver"

rc=0; cases=0

# ------------------------------------------------------------------------------------------------
# A scratch checkout so section A measures the fixture, not the developer's tree.
for f in backup-env.sh preflight.sh verify-openarchiver.sh stage-mailbox.sh dedup-experiment.sh inventory-mailboxes.sh; do
  printf '#!/usr/bin/env bash\n: "stub"\n' >"$FAKEREPO/openarchiver/$f"
done
# preflight shells out to the REAL backup-env.sh for the digest, so use the real one.
cp "$ROOT/openarchiver/backup-env.sh" "$FAKEREPO/openarchiver/backup-env.sh"
printf 'FALLBACK_VERSION="v0.5.2"\n' >"$FAKEREPO/archive-openarchiver-setup.sh"
( cd "$FAKEREPO" && git init -q . && git add -A \
  && git -c user.email=drill@example.invalid -c user.name=drill commit -qm fixture ) >/dev/null 2>&1

# ------------------------------------------------------------------------------------------------
# Stub binaries. Each reads its behaviour from files under $STATE, so a case is one line of setup.
cat >"$STUBS/sudo" <<'S'
#!/usr/bin/env bash
while [ "${1:-}" = "-n" ] || [ "${1:-}" = "-S" ]; do shift; done
exec "$@"
S
cat >"$STUBS/docker" <<'S'
#!/usr/bin/env bash
st="$STUB_STATE"
case "$1" in
  ps)   if printf '%s ' "$@" | grep -q 'Status'; then cat "$st/containers"; else cut -f1 "$st/containers"; fi ;;
  inspect) cat "$st/image" ;;
  compose) [ "${2:-}" = "config" ] && cat "$st/compose" ;;
  exec)
    case "${2:-}" in
      openarchiver-app)        cat "$st/backend" ;;
      openarchiver-postgres)   sql="${!#}"; bash "$st/sqlstub" "$sql" ;;
      caddy)                   cat "$st/caddyfile" 2>/dev/null ;;
    esac ;;
esac
exit 0
S
cat >"$STUBS/curl" <<'S'
#!/usr/bin/env bash
cat "$STUB_STATE/http"
S
cat >"$STUBS/hostname" <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "-I" ] && { cat "$STUB_STATE/ips"; exit 0; }
echo archive-pc
S
cat >"$STUBS/tailscale" <<'S'
#!/usr/bin/env bash
[ -s "$STUB_STATE/tsip" ] || exit 1
case "$1" in
  ip)     cat "$STUB_STATE/tsip" ;;
  status) echo "100.64.0.1  archive-pc  linux  -" ;;
esac
S
cat >"$STUBS/df" <<'S'
#!/usr/bin/env bash
g="$(cat "$STUB_STATE/disk_g")"
echo "Filesystem Size Used Avail Use% Mounted"
echo "/dev/nvme0n1 500G 100G ${g}G 20% /"
S
cat >"$STUBS/free" <<'S'
#!/usr/bin/env bash
m="$(cat "$STUB_STATE/mem_mb")"
echo "              total  used  free  shared  buff/cache  available"
echo "Mem:          16000  4000  2000     100       10000  ${m}"
S
cat >"$STUBS/findmnt" <<'S'
#!/usr/bin/env bash
echo "ro,relatime"
S
# Caddy on the real box is a systemd service, not a container — the stub has to model that, or the
# drill would keep certifying a detection path the box never takes.
cat >"$STUBS/systemctl" <<'S'
#!/usr/bin/env bash
case "$1" in
  is-active)       [ "$(cat "$STUB_STATE/caddy")" = "active" ] && exit 0 || exit 3 ;;
  list-unit-files) [ "$(cat "$STUB_STATE/caddy")" = "absent" ] || echo "caddy.service enabled" ;;
esac
exit 0
S
cat >"$STATE/sqlstub" <<'S'
#!/usr/bin/env bash
q="$1"
case "$q" in
  "select 1")                                        echo 1 ;;
  *"count(*) from archived_emails"*"message_id"*)    echo 1 ;;
  *"table_name='ingestion_sources'"*)                echo 1 ;;
  *"string_agg(column_name"*)                        echo "id,name,provider" ;;
  *"from ingestion_sources order by"*)               printf '1  ZZ-SYNTHETIC-VERIFY\n2  archive.pst\n3  archive old.pst\n' ;;
  *"count(*) from ingestion_sources"*)               echo 3 ;;
  *"column_name='message_id'"*)                      echo 1 ;;
  *"having count(*)>1"*)                             echo 330 ;;
  *"count(distinct"*)                                echo 330 ;;
  *"count(*) from archived_emails"*)                 echo 1222 ;;
  *)                                                 echo "" ;;
esac
S
chmod +x "$STUBS"/* "$STATE/sqlstub"

# ------------------------------------------------------------------------------------------------
# A healthy box, as the baseline every case mutates.
reset_healthy(){
  printf 'openarchiver-app\tUp 2 days\nopenarchiver-postgres\tUp 2 days\nopenarchiver-valkey\tUp 2 days\nopenarchiver-meilisearch\tUp 2 days\nopenarchiver-tika\tUp 2 days\n' >"$STATE/containers"
  echo "v0.5.2"  >"$STATE/image"
  echo "UP"      >"$STATE/backend"
  echo "200"     >"$STATE/http"
  echo "192.168.1.42 100.64.0.1" >"$STATE/ips"
  echo "100.64.0.1" >"$STATE/tsip"
  echo "500"     >"$STATE/disk_g"
  echo "10600"   >"$STATE/mem_mb"
  echo "active" >"$STATE/caddy"
  printf 'http://mail.home {\n\treverse_proxy 127.0.0.1:3010\n}\n' >"$STATE/caddyfile"
  cat >"$STATE/compose" <<'C'
services:
  open-archiver:
    environment:
      MEILI_NO_ANALYTICS: "true"
    ports:
      - mode: ingress
        target: 3000
        published: "3010"
        host_ip: 127.0.0.1
    volumes:
      - type: bind
        source: /srv/apps/openarchiver/import
        target: /import
        read_only: true
C
  cat >"$APP/docker-compose.yml" <<'C'
services:
  open-archiver:
    image: logiclabshq/open-archiver:v0.5.2
C
  cat >"$APP/.env" <<'E'
NODE_ENV=production
APP_URL=http://127.0.0.1:8931
ORIGIN=http://127.0.0.1:8931
JWT_SECRET=3333333333333333333333333333333333333333333333333333333333333333
ENCRYPTION_KEY=1111111111111111111111111111111111111111111111111111111111111111
STORAGE_ENCRYPTION_KEY=2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_PASSWORD=44444444444444444444444444444444
DATABASE_URL=postgresql://openarchiver:44444444444444444444444444444444@openarchiver-postgres:5432/open_archive
MEILI_MASTER_KEY=555555555555555555555555555555555555555555555555
REDIS_PASSWORD=66666666666666666666666666666666
STORAGE_TYPE=local
BODY_SIZE_LIMIT=100M
PDF_PARSE_TIMEOUT_MS=300000
INGESTION_WORKER_CONCURRENCY=2
ALL_INCLUSIVE_ARCHIVE=true
ENABLE_DELETION=false
E
}

run_preflight(){
  PATH="$STUBS:$PATH" STUB_STATE="$STATE" \
  OPENARCHIVER_DIR="$APP" REPO_DIR="$FAKEREPO" ARCHIVE_ROOT="$WORK/archive" \
  CADDYFILE="$STATE/caddyfile" \
    bash "$TOOL" --no-network "$@" 2>&1
}

# expect_block <name> <must-say>   — the planted fault must BLOCK (exit 1) and name its reason.
expect_block(){
  local name="$1" must="$2"; shift 2
  cases=$((cases+1))
  local out status
  out="$(run_preflight "$@")"; status=$?
  if [ "$status" -ne 1 ]; then
    bad "$name — expected a BLOCK (exit 1), got exit $status"
    printf '%s\n' "$out" | grep -E 'BLOCK|VERDICT' | sed 's/^/      /'
    rc=1
  elif ! printf '%s' "$out" | grep -qF "$must"; then
    bad "$name — it blocked, but never said: $must"
    printf '%s\n' "$out" | grep -E 'BLOCK' | sed 's/^/      /'
    rc=1
  else
    ok "$name"
  fi
  reset_healthy
}

# ------------------------------------------------------------------------------------------------
hdr "A healthy box does not block"
reset_healthy
cases=$((cases+1))
out="$(run_preflight)"; status=$?
if [ "$status" -eq 1 ]; then
  bad "the healthy fixture BLOCKED — the check is too strict to be useful"
  printf '%s\n' "$out" | grep -E 'BLOCK' | sed 's/^/      /'
  rc=1
else
  ok "healthy fixture produces no blockers (exit $status)"
fi

# Without the operator's assertion, the off-box backup MUST stay unknown — this box cannot see it.
cases=$((cases+1))
if printf '%s' "$out" | grep -qF "whether a verified copy exists OFF this box"; then
  ok "the off-box backup is reported UNKNOWN, not assumed"
else
  bad "preflight did not flag the off-box backup as unknown"; rc=1
fi

# With a matching assertion it closes; the digest is re-derived from the live file, not taken on faith.
cases=$((cases+1))
live_sha="$(OPENARCHIVER_ENV="$APP/.env" bash "$ROOT/openarchiver/backup-env.sh" fingerprint 2>/dev/null | sed -n 's/^  sha256: //p' | head -1)"
if [ -z "$live_sha" ]; then
  bad "could not derive the fixture .env digest — the drill cannot test the assertion path"; rc=1
else
  # Capture, then grep. Piping run_preflight into grep would put preflight's exit status into a
  # pipefail pipeline, so a passing check reads as a failure purely because unknowns exit 3.
  assert_out="$(run_preflight --env-backup-verified "$live_sha")"
  if printf '%s' "$assert_out" | grep -qF "the lockout gate is closed"; then
    ok "a matching --env-backup-verified digest closes the lockout gate"
  else
    bad "a matching --env-backup-verified digest did not close the gate"
    printf '%s\n' "$assert_out" | grep -E 'UNKNOWN|BLOCK|OK.*\.env' | sed 's/^/      /'
    rc=1
  fi
fi

hdr "Every condition it claims to detect, planted"

expect_block "a STALE .env backup (real copy, wrong file)" "the backup is STALE" \
  --env-backup-verified 0000000000000000000000000000000000000000000000000000000000000000

echo "DOWN" >"$STATE/backend"
expect_block "backend dead behind a healthy frontend" "THE BACKEND IS NOT LISTENING"

grep -v 'openarchiver-tika' "$STATE/containers" >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/containers"
expect_block "a missing container" "expected 5 containers"

grep -v 'MEILI_NO_ANALYTICS' "$STATE/compose" >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/compose"
expect_block "Meilisearch telemetry back on" "MEILI_NO_ANALYTICS not set"

sed -i 's|host_ip: 127.0.0.1|host_ip: 0.0.0.0|' "$STATE/compose"
expect_block "a port published on all interfaces" "disallowed interface"

sed -i 's|host_ip: 127.0.0.1|host_ip: 192.168.1.42|' "$STATE/compose"
expect_block "a port published on a LAN address" "disallowed interface"

# 100.200.x.x starts with "100." and is ordinary PUBLIC address space. A prefix match would let it
# through, which is precisely how a widened rule stops being a rule.
sed -i 's|host_ip: 127.0.0.1|host_ip: 100.200.1.1|' "$STATE/compose"
expect_block "a public 100.200.x.x address (not the tailnet)" "disallowed interface"

sed -i '/host_ip: 127.0.0.1/d' "$STATE/compose"
expect_block "a port published with no host_ip at all" "no host_ip"

# ...and the tailnet bind the operator actually asked for must NOT block, or the widening did
# nothing. Both directions, or neither result means anything.
sed -i 's|host_ip: 127.0.0.1|host_ip: 100.64.0.1|' "$STATE/compose"
cases=$((cases+1))
ts_out="$(run_preflight)"; ts_status=$?
if [ "$ts_status" -eq 1 ]; then
  bad "a Tailscale bind (100.64.0.1) was BLOCKED — the tailnet exception does not work"
  printf '%s\n' "$ts_out" | grep -E 'BLOCK' | sed 's/^/      /'
  rc=1
elif printf '%s' "$ts_out" | grep -qF "loopback or the tailnet"; then
  ok "a Tailscale bind (100.64.0.1) is accepted"
else
  bad "a Tailscale bind was not recognised as such"
  printf '%s\n' "$ts_out" | grep -iE 'published|interface' | sed 's/^/      /'
  rc=1
fi
reset_healthy

printf '      - type: bind\n        source: %s/archive\n        target: /archive\n' "$WORK" >>"$STATE/compose"
expect_block "the archive mounted into a container" "THE ARCHIVE IS MOUNTED INTO A CONTAINER"

sed -i 's/read_only: true/read_only: false/' "$STATE/compose"
expect_block "a writable import mount" "import mount is NOT read-only"

sed -i '/^STORAGE_TYPE=/d' "$APP/.env"
expect_block "STORAGE_TYPE dropped (kills the backend silently)" "STORAGE_TYPE is 'unset'"

sed -i 's/^ENABLE_DELETION=false/ENABLE_DELETION=true/' "$APP/.env"
expect_block "deletion re-enabled" "the app can delete archived mail"

sed -i 's/^PDF_PARSE_TIMEOUT_MS=.*/PDF_PARSE_TIMEOUT_MS=20000/' "$APP/.env"
expect_block "an OCR timeout too short for a multi-page fax" "too low for multi-page scanned faxes"

printf 'GOOGLE_CLIENT_SECRET=abc123def456\n' >>"$APP/.env"
expect_block "cloud connector credentials in .env" "cloud connector credentials present"

echo "v0.5.1" >"$STATE/image"
expect_block "image drift between compose and the running container" "DRIFT"

echo "169.254.19.137" >"$STATE/ips"
expect_block "a link-local-only address (no DHCP lease)" "no DHCP lease"

echo "40" >"$STATE/disk_g"
expect_block "too little disk for the projected corpus" "below what the full corpus needs"

echo "2048" >"$STATE/mem_mb"
expect_block "too little RAM for the stack" "below the stack's ~4 GiB floor"

echo "inactive" >"$STATE/caddy"
expect_block "Caddy installed but stopped" "Caddy is installed but NOT running"

# ...and the healthy path must recognise the systemd service, or the block above proves nothing
# about the detection actually used on the box.
cases=$((cases+1))
out="$(run_preflight)"
if printf '%s' "$out" | grep -qF "Caddy is running (systemd service)"; then
  ok "a running Caddy systemd service is detected (not just a container)"
else
  bad "the systemd Caddy service was not detected — this is how it runs on the box"
  printf '%s\n' "$out" | grep -iE 'caddy' | sed 's/^/      /'; rc=1
fi

cases=$((cases+1))
if printf '%s' "$out" | grep -qF "mail.<domain> route is present"; then
  ok "the mail.<domain> route is read from the Caddyfile on disk"
else
  bad "the mail route was not found in the Caddyfile"; rc=1
fi

printf 'http://photos.home {\n\treverse_proxy 127.0.0.1:2283\n}\n' >"$STATE/caddyfile"
cases=$((cases+1))
noroute_out="$(run_preflight)"
if printf '%s' "$noroute_out" | grep -qF "not stood up yet"; then
  ok "a Caddyfile without the mail route is reported as not stood up"
else
  bad "a missing mail route was not reported"; rc=1
fi
reset_healthy

# ------------------------------------------------------------------------------------------------
hdr "Summary"
if (( rc )); then
  bad "preflight drill FAILED ($cases cases run)"
else
  ok "preflight drill passed — $cases cases, both directions"
fi
exit "$rc"
