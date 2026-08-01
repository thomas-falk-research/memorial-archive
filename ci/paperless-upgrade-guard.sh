#!/usr/bin/env bash
# ci/paperless-upgrade-guard.sh — prove archive-paperless-setup.sh cannot walk into the Paperless
# v2 -> v3 migration by accident.
#
# Paperless-ngx v3 is a one-way door: it can only be entered from v2.20.15, v3.0.1 shipped a broken
# migration, and the upstream compose has moved BOTH the Postgres image and the pgdata mount path.
# Applying that silently initialises a blank cluster in the existing volume — the app comes up with
# no documents, tags or correspondents while the files sit untouched in the media volume. The setup
# script guards against all of it; this drill proves the guards have teeth by driving the REAL script
# against stub docker/curl/git binaries and asserting, for each refusal, that:
#
#   * the script exits non-zero,
#   * `docker compose up -d` was NEVER reached, and
#   * the live docker-compose.yml is byte-identical to what it was before the run.
#
# Needs no Docker, no network and no sudo (a stub `sudo` just runs the command) — scratch dirs only,
# so it runs in the static CI job and via ./ci/run.sh.
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1

SCRIPT="archive-paperless-setup.sh"
[[ -f "$SCRIPT" ]] || { bad "$SCRIPT not found"; exit 1; }

fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# The script refuses to run as root (it sudo's for itself). CI images often ARE root, and that
# precondition is not what we're testing here — so when we're root, run a copy with just that one
# guard line removed, and say so out loud.
RUN_SCRIPT="$WORK/paperless-setup.sh"
cp "$SCRIPT" "$RUN_SCRIPT"
if [[ "${EUID}" -eq 0 ]]; then
  # SC2016: the single quotes are deliberate — we match the LITERAL string ${EUID} in the script.
  # shellcheck disable=SC2016
  sed -i 's/^\[\[ "${EUID}" -ne 0 \]\] || die .*/: # EUID guard removed by ci drill (running as root)/' "$RUN_SCRIPT"
  warn "running as root — the script's own 'do not run as root' guard was stubbed out for this drill."
fi

# ---- stubs -------------------------------------------------------------------------------------
# sudo: run the command as-is (swallow -v); everything else the script shells out to is real.
cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && exit 0
exec "$@"
STUB
# docker: `info` and `compose config` succeed; every `compose` call is logged so the drill can assert
# that `up -d` was never reached on a refused run.
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "${1:-}" in
  info) exit 0 ;;
  compose) exit 0 ;;
esac
exit 0
STUB
# curl: serve the fixture compose for whichever tag was requested; the env template is a stub.
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
url=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
case "$url" in
  *docker-compose.env)      printf '# stub env template\n' >"$out" ;;
  *docker-compose.postgres.yml)
      tag="${url#*paperless-ngx/paperless-ngx/}"; tag="${tag%%/*}"
      src="$FIXTURES/compose-${tag}.yml"
      [[ -f "$src" ]] || { printf 'stub curl: no fixture for tag %s\n' "$tag" >&2; exit 22; }
      cat "$src" >"$out" ;;
  *) exit 22 ;;
esac
STUB
# git ls-remote: whatever tag list the current case wants "latest" to resolve to.
cat >"$BIN/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "ls-remote" ]]; then printf 'sha\trefs/tags/%s\n' "$UPSTREAM_LATEST"; exit 0; fi
exec /usr/bin/git "$@"
STUB
# hostname may be absent in a slim CI image; the script needs it early and runs under `set -e`.
command -v hostname >/dev/null 2>&1 || printf '#!/usr/bin/env bash\nprintf "ci-box\\n"\n' >"$BIN/hostname"
chmod +x "$BIN"/*

# ---- fixtures: the upstream compose as it really differs across these tags ----------------------
FIXTURES="$WORK/fixtures"; mkdir -p "$FIXTURES"
make_compose() {  # make_compose <file> <db-image> <pgdata-mount>
  cat >"$1" <<YML
services:
  broker:
    image: docker.io/library/redis:8
    volumes:
      - redisdata:/data
  db:
    image: $2
    volumes:
      - $3
    environment:
      POSTGRES_DB: paperless
  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    depends_on:
      - db
      - broker
    ports:
      - "8000:8000"
    volumes:
      - data:/usr/src/paperless/data
      - media:/usr/src/paperless/media
    env_file: docker-compose.env
volumes:
  data:
  media:
  pgdata:
  redisdata:
YML
}
make_compose "$FIXTURES/compose-v2.20.14.yml" "docker.io/library/postgres:16" "pgdata:/var/lib/postgresql/data"
make_compose "$FIXTURES/compose-v2.20.15.yml" "docker.io/library/postgres:16" "pgdata:/var/lib/postgresql/data"
make_compose "$FIXTURES/compose-v3.0.3.yml"   "docker.io/library/postgres:18" "pgdata:/var/lib/postgresql"
# A hypothetical patch release that moves the database layout WITHOUT a major bump — the trap case 5
# exists for. (Upstream really did move both across recent tags; this pins the behaviour we want.)
make_compose "$FIXTURES/compose-v2.20.16.yml" "docker.io/library/postgres:18" "pgdata:/var/lib/postgresql"
export FIXTURES

# ---- harness -----------------------------------------------------------------------------------
# install_at <appdir> <tag> — a plausible existing install at that version.
install_at() {
  local dir="$1" tag="$2"
  mkdir -p "$dir/consume" "$dir/export"
  cp "$FIXTURES/compose-v${tag}.yml" "$dir/docker-compose.yml"
  cat >"$dir/docker-compose.override.yml" <<YML
# Managed by archive-paperless-setup.sh — pin the image and the published port.
services:
  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:${tag}
    ports:
      - "8000:8000"
YML
  printf '# ---- Added by archive-paperless-setup.sh ----\nPAPERLESS_ADMIN_USER=admin\n' >"$dir/docker-compose.env"
}

# run_case <name> <appdir> <upstream-latest> [args...] — returns the script's exit code, and leaves
# $LAST_OUT / $LAST_DOCKER_LOG for assertions.
run_case() {
  local dir="$2" latest="$3"   # $1 is a human label, for readability at the call sites
  shift 3
  LAST_OUT="$WORK/out.$$"; LAST_DOCKER_LOG="$WORK/dockerlog.$$"
  : >"$LAST_DOCKER_LOG"
  PATH="$BIN:$PATH" PAPERLESS_DIR="$dir" UPSTREAM_LATEST="$latest" DOCKER_LOG="$LAST_DOCKER_LOG" \
    PAPERLESS_VERSION="${CASE_VERSION:-}" \
    bash "$RUN_SCRIPT" "$@" >"$LAST_OUT" 2>&1
  return $?
}
sum_of() { [[ -f "$1" ]] && sha256sum <"$1" | awk '{print $1}' || printf 'absent'; }
deployed_tag() { sed -n 's#.*paperless-ngx:##p' "$1/docker-compose.override.yml" 2>/dev/null | head -1 | tr -d '[:space:]'; }
saw_up() { grep -q 'compose up -d' "$LAST_DOCKER_LOG"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fails=1; fi; }

hdr "1. fresh install deploys the recorded pin — never a floating 'latest'"
D="$WORK/fresh"; mkdir -p "$D"
CASE_VERSION="" run_case fresh "$D" "v9.9.9" --yes; rc=$?
pin="$(grep -E '^FALLBACK_VERSION=' "$SCRIPT" | head -1 | sed -E 's/.*"v?([^"]*)".*/\1/')"
check "exits 0"                       "$rc"                  "0"
check "deployed the pin ($pin)"       "$(deployed_tag "$D")" "$pin"
if saw_up; then ok "started the stack"; else bad "never ran compose up -d"; fails=1; fi

hdr "2. plain re-run keeps the installed tag (no silent drift to latest)"
D="$WORK/rerun"; install_at "$D" "2.20.15"
CASE_VERSION="" run_case rerun "$D" "v3.0.3" --yes; rc=$?
check "exits 0"                    "$rc"                  "0"
check "still on 2.20.15"           "$(deployed_tag "$D")" "2.20.15"

hdr "3. --upgrade across the v2 -> v3 major boundary is REFUSED"
D="$WORK/major"; install_at "$D" "2.20.15"
before="$(sum_of "$D/docker-compose.yml")"
CASE_VERSION="" run_case major "$D" "v3.0.3" --yes --upgrade; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "exits non-zero"; else bad "exited 0 — the major jump was allowed"; fails=1; fi
if grep -qi 'refusing' "$LAST_OUT"; then ok "says why it refused"; else bad "no refusal message"; fails=1; fi
check "compose untouched"          "$(sum_of "$D/docker-compose.yml")" "$before"
check "still pinned to 2.20.15"    "$(deployed_tag "$D")"              "2.20.15"
if saw_up; then bad "ran compose up -d despite refusing"; fails=1; else ok "never started the stack"; fi

hdr "4. --upgrade-major without an export is REFUSED (no way back)"
D="$WORK/noexport"; install_at "$D" "2.20.15"
before="$(sum_of "$D/docker-compose.yml")"
CASE_VERSION="" run_case noexport "$D" "v3.0.3" --yes --upgrade-major; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "exits non-zero"; else bad "exited 0 with no export present"; fails=1; fi
if grep -q 'document_exporter' "$LAST_OUT"; then ok "tells you how to take an export"; else bad "no export instructions"; fails=1; fi
check "compose untouched"          "$(sum_of "$D/docker-compose.yml")" "$before"
if saw_up; then bad "ran compose up -d despite refusing"; fails=1; else ok "never started the stack"; fi

hdr "5. a database-layout change is REFUSED even within one major"
# Same major (2.20.15 -> 2.20.15) but the live compose is the older postgres:16 layout: exactly the
# 'blank cluster' trap, and it must be caught on its own merits, not as a side effect of the major check.
D="$WORK/dblayout"; install_at "$D" "2.20.15"
before="$(sum_of "$D/docker-compose.yml")"
CASE_VERSION="2.20.16" run_case dblayout "$D" "v2.20.16" --yes; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "exits non-zero"; else bad "exited 0 — a db-layout change slipped through"; fails=1; fi
if grep -qi 'DATABASE layout' "$LAST_OUT"; then ok "names the layout change"; else bad "did not explain the db-layout change"; fails=1; fi
check "compose untouched"          "$(sum_of "$D/docker-compose.yml")" "$before"
if saw_up; then bad "ran compose up -d despite refusing"; fails=1; else ok "never started the stack"; fi

hdr "6. a DOWNGRADE onto an already-migrated database is REFUSED"
D="$WORK/downgrade"; install_at "$D" "2.20.15"
before="$(sum_of "$D/docker-compose.yml")"
CASE_VERSION="2.20.14" run_case downgrade "$D" "v2.20.14" --yes; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "exits non-zero"; else bad "exited 0 — downgrade allowed"; fails=1; fi
check "compose untouched"          "$(sum_of "$D/docker-compose.yml")" "$before"

hdr "7. the sanctioned path works: --upgrade-major WITH an export applies the new version"
D="$WORK/sanctioned"; install_at "$D" "2.20.15"
printf '{"version":"2.20.15"}\n' >"$D/export/manifest.json"
CASE_VERSION="" run_case sanctioned "$D" "v3.0.3" --yes --upgrade-major; rc=$?
check "exits 0"                    "$rc"                  "0"
check "deployed 3.0.3"             "$(deployed_tag "$D")" "3.0.3"
if [[ -f "$D/docker-compose.yml.bak-2.20.15" ]]; then ok "kept a rollback copy of the old compose"; else bad "no docker-compose.yml.bak-2.20.15 rollback copy"; fails=1; fi
if saw_up; then ok "started the stack"; else bad "never ran compose up -d"; fails=1; fi
if grep -q 'PAPERLESS_ADMIN_USER=admin' "$D/docker-compose.env"; then ok "left the existing env (password/secret) intact"; else bad "clobbered docker-compose.env on an upgrade"; fails=1; fi

hdr "Summary"
if (( fails )); then bad "paperless upgrade-guard drill FAILED"; else ok "paperless upgrade guard holds"; fi
exit "$fails"
