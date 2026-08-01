#!/usr/bin/env bash
#
# ci/openarchiver-env-guard.sh — drill openarchiver/backup-env.sh in BOTH directions.
#
# The rule this exists to satisfy: a verification that cannot fail is not evidence. It is not enough
# to show the tool says PASS on a good backup; it has to be shown saying FAIL, for the right reason,
# on every way a backup of this file has plausibly gone wrong:
#
#   the copy never happened · the copy is the zero-byte file sudo leaves behind · the copy is a
#   captured error message · the copy was truncated in transit · line endings were rewritten · an
#   irreplaceable key is missing, empty, or the wrong shape · the copy belongs to a DIFFERENT
#   install · there is no reference at all, so nothing has actually been compared.
#
# Plus the two properties the tool promises about its own output: it never prints a secret value,
# and it aborts rather than printing one if that were ever about to happen.
#
# Entirely synthetic. It builds fake .env files in a scratch directory with obviously-fake secrets;
# it never reads /srv/apps/openarchiver, never touches a real install, and never needs Docker.
#
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(repo_root)"
TOOL="$ROOT/openarchiver/backup-env.sh"

[ -x "$TOOL" ] || [ -f "$TOOL" ] || { bad "missing $TOOL — nothing to drill"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rc=0
cases=0

# Obviously-fake, correctly-shaped secrets: 64 hex characters for the two irreplaceable keys, so a
# failure in the drill is always about the property under test and never about the fixture.
K_ENC="1111111111111111111111111111111111111111111111111111111111111111"
K_STO="2222222222222222222222222222222222222222222222222222222222222222"
K_JWT="3333333333333333333333333333333333333333333333333333333333333333"
K_PG="44444444444444444444444444444444"
K_MEILI="555555555555555555555555555555555555555555555555"
K_REDIS="66666666666666666666666666666666"

# make_env <path> [enc] [sto] — a structurally complete Open Archiver .env.
make_env(){
  local path="$1" enc="${2:-$K_ENC}" sto="${3:-$K_STO}"
  cat >"$path" <<ENVEOF
# Managed by archive-openarchiver-setup.sh — SECRETS. Keep private (chmod 600).
NODE_ENV=production
APP_URL=http://127.0.0.1:8931

JWT_SECRET=$K_JWT
ENCRYPTION_KEY=$enc
STORAGE_ENCRYPTION_KEY=$sto

POSTGRES_DB=open_archive
POSTGRES_PASSWORD=$K_PG
DATABASE_URL=postgresql://openarchiver:$K_PG@openarchiver-postgres:5432/open_archive

MEILI_MASTER_KEY=$K_MEILI
MEILI_NO_ANALYTICS=true

REDIS_PASSWORD=$K_REDIS

STORAGE_TYPE=local
STORAGE_LOCAL_ROOT_PATH=/var/lib/open-archiver
ENABLE_DELETION=false
ENVEOF
}

# run_case <name> <expect: pass|fail> <must-say> -- <args...>
# Asserts the exit status AND that the output names the right reason. A test that accepts any
# non-zero exit would pass when the tool crashed for an unrelated reason, which proves nothing.
run_case(){
  local name="$1" expect="$2" must="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  cases=$((cases+1))
  local out status
  out="$(OPENARCHIVER_ENV="$LIVE" bash "$TOOL" "$@" 2>&1)"; status=$?

  local status_ok=0
  case "$expect" in
    pass) [ "$status" -eq 0 ] && status_ok=1 ;;
    fail) [ "$status" -ne 0 ] && status_ok=1 ;;
  esac

  if [ "$status_ok" -ne 1 ]; then
    bad "$name — expected $expect, got exit $status"
    printf '%s\n' "$out" | sed 's/^/      /'
    rc=1
    return
  fi
  if [ -n "$must" ] && ! printf '%s' "$out" | grep -qF "$must"; then
    bad "$name — exit was right ($status) but the output never said: $must"
    printf '%s\n' "$out" | sed 's/^/      /'
    rc=1
    return
  fi
  ok "$name"
}

# ------------------------------------------------------------------------------------------------
LIVE="$WORK/live.env"
make_env "$LIVE"
GOOD_SHA="$(sha256sum "$LIVE" | awk '{print $1}')"

hdr "The tool describes a healthy .env"

run_case "fingerprint reports a well-formed live .env" pass "sha256:" -- fingerprint

# The headline promise: this output is meant to be safe to carry off the box.
hdr "It never prints a secret value"
cases=$((cases+1))
fp_out="$(OPENARCHIVER_ENV="$LIVE" bash "$TOOL" fingerprint 2>&1)"
leaked=""
for secret in "$K_ENC" "$K_STO" "$K_JWT" "$K_PG" "$K_MEILI" "$K_REDIS"; do
  printf '%s' "$fp_out" | grep -qF "$secret" && leaked="$leaked $secret"
done
if [ -n "$leaked" ]; then
  bad "fingerprint LEAKED a secret value:$leaked"
  rc=1
else
  ok "no secret value appears anywhere in the fingerprint output"
fi

# And the guard behind that promise has to be shown firing, not merely present. POSTGRES_PASSWORD is
# set to the literal text of another key's NAME, which the report prints — so the guard must catch it.
cases=$((cases+1))
trap_env="$WORK/leaky.env"
make_env "$trap_env"
sed -i 's/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=MEILI_MASTER_KEY/' "$trap_env"
sed -i 's|^DATABASE_URL=.*|DATABASE_URL=postgresql://openarchiver:MEILI_MASTER_KEY@openarchiver-postgres:5432/open_archive|' "$trap_env"
guard_out="$(OPENARCHIVER_ENV="$trap_env" bash "$TOOL" fingerprint 2>&1)"; guard_status=$?
if [ "$guard_status" -eq 0 ]; then
  bad "the output guard did NOT fire when a secret value was about to be printed"
  rc=1
elif ! printf '%s' "$guard_out" | grep -qF "Refusing to print it"; then
  bad "the run failed, but not because the output guard fired — it said:"
  printf '%s\n' "$guard_out" | sed 's/^/      /'
  rc=1
else
  ok "the output guard fires and aborts when a secret value would be printed"
fi

# ------------------------------------------------------------------------------------------------
hdr "A faithful copy verifies — against the box, a digest, and a manifest"

COPY="$WORK/good-copy.env"
cp "$LIVE" "$COPY"
run_case "verify against the live .env"        pass "VERIFIED" -- verify "$COPY"
run_case "verify against a matching --expect"  pass "VERIFIED" -- verify "$COPY" --expect "$GOOD_SHA"

MAN="$WORK/manifest.txt"
run_case "fingerprint writes a manifest"       pass "manifest written" -- fingerprint --manifest "$MAN"
cases=$((cases+1))
man_leak=""
for secret in "$K_ENC" "$K_STO" "$K_JWT" "$K_PG" "$K_MEILI" "$K_REDIS"; do
  grep -qF "$secret" "$MAN" 2>/dev/null && man_leak="$man_leak $secret"
done
if [ -n "$man_leak" ]; then bad "the manifest contains secret values:$man_leak"; rc=1
else ok "the manifest carries digests only — no secret values"; fi
run_case "verify against the manifest"         pass "VERIFIED" -- verify "$COPY" --manifest "$MAN"
run_case "refuses to overwrite a manifest"     fail "refusing to overwrite" -- fingerprint --manifest "$MAN"

# ------------------------------------------------------------------------------------------------
hdr "Every way the backup goes wrong is caught, and named"

run_case "the copy was never made" fail "does not exist" -- verify "$WORK/not-there.env" --expect "$GOOD_SHA"

# The one that matters most: `ssh HOST 'sudo cat ...' > file` with sudo unable to prompt.
: >"$WORK/empty.env"
run_case "the copy is zero bytes (sudo could not prompt)" fail "EMPTY (0 bytes)" \
  -- verify "$WORK/empty.env" --expect "$GOOD_SHA"

printf 'sudo: a terminal is required to read the password; either use the -S option\n' >"$WORK/errmsg.env"
run_case "the copy is a captured error message" fail "does not look like an Open Archiver .env" \
  -- verify "$WORK/errmsg.env" --expect "$GOOD_SHA"

head -c 200 "$LIVE" >"$WORK/truncated.env"
run_case "the copy was truncated in transit" fail "TRUNCATED" -- verify "$WORK/truncated.env"

sed 's/$/\r/' "$LIVE" >"$WORK/crlf.env"
run_case "line endings were rewritten to CRLF" fail "carriage return" -- verify "$WORK/crlf.env"

grep -v '^ENCRYPTION_KEY=' "$LIVE" >"$WORK/no-enc.env"
run_case "ENCRYPTION_KEY missing" fail "cannot be regenerated" -- verify "$WORK/no-enc.env" --expect "$GOOD_SHA"

sed 's/^ENCRYPTION_KEY=.*/ENCRYPTION_KEY=/' "$LIVE" >"$WORK/blank-enc.env"
run_case "ENCRYPTION_KEY present but empty" fail "cannot be regenerated" \
  -- verify "$WORK/blank-enc.env" --expect "$GOOD_SHA"

sed 's/^ENCRYPTION_KEY=.*/ENCRYPTION_KEY=deadbeef/' "$LIVE" >"$WORK/short-enc.env"
run_case "ENCRYPTION_KEY is the wrong shape" fail "not 32 bytes of hex" \
  -- verify "$WORK/short-enc.env" --expect "$GOOD_SHA"

# A structurally perfect .env from a DIFFERENT install. Every structural check passes; only the
# comparison against a reference can catch it — which is the whole reason a reference is mandatory.
OTHER="$WORK/other-install.env"
make_env "$OTHER" "$K_ENC" "9999999999999999999999999999999999999999999999999999999999999999"
run_case "a valid .env from another install (vs the box)"   fail "STORAGE_ENCRYPTION_KEY" -- verify "$OTHER"
run_case "a valid .env from another install (vs manifest)"  fail "STORAGE_ENCRYPTION_KEY" -- verify "$OTHER" --manifest "$MAN"
run_case "a wrong --expect digest is rejected" fail "MISMATCH" \
  -- verify "$COPY" --expect "0000000000000000000000000000000000000000000000000000000000000000"

# ------------------------------------------------------------------------------------------------
hdr "It refuses to imply success when it has verified nothing"

# No --expect, no --manifest, and no live .env to compare against: structure is fine, but nothing
# has been proven. Reporting PASS here would be the exact failure mode rule 8 was written about.
cases=$((cases+1))
noref_out="$(OPENARCHIVER_ENV="$WORK/absent-live.env" bash "$TOOL" verify "$COPY" 2>&1)"; noref_status=$?
if [ "$noref_status" -eq 0 ]; then
  bad "verify PASSED with no reference — it compared the copy against nothing"
  rc=1
elif ! printf '%s' "$noref_out" | grep -qF "UNVERIFIED"; then
  bad "verify failed without a reference, but did not say UNVERIFIED:"
  printf '%s\n' "$noref_out" | sed 's/^/      /'
  rc=1
else
  ok "with no reference it reports UNVERIFIED and exits non-zero"
fi

# The same refusal on the fingerprint side: a live .env that is missing must not fingerprint "fine".
run_case "fingerprint of a missing .env fails" fail "does not exist" -- fingerprint "$WORK/absent-live.env"

# ------------------------------------------------------------------------------------------------
hdr "Summary"
if (( rc )); then
  bad "backup-env drill FAILED ($cases cases run)"
else
  ok "backup-env drill passed — $cases cases, both directions"
fi
exit "$rc"
