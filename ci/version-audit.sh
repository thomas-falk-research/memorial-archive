#!/usr/bin/env bash
# ci/version-audit.sh — confirm every app's FALLBACK image tag actually exists upstream.
#
# Each app setup script resolves the latest upstream release at install time and, only if that lookup
# fails (offline box, API hiccup), falls back to a pinned FALLBACK_VERSION. A fallback pointing at a
# tag that no longer exists would leave such an install with a BROKEN pin — found the hard way, at
# deploy time, on the family's box. This rebuilds each fallback ref exactly as its script would
# (extracting the script's own FALLBACK_VERSION, then applying that app's tag rule) and checks it.
#
# IMPORTANT — it must never cry wolf. We list a repo's tags once and test membership locally, rather
# than fetching each manifest (Docker Hub rate-limits anonymous manifest pulls hard, especially from
# CI). And it FAILS only on a tag the registry *confirms* is absent; if a repo can't be reached
# (offline, rate-limited), that app is reported "undetermined" (a warning) — never a red build.
#
# Needs skopeo (its CI job and weekly cron install it). With no skopeo, or no registry egress, it
# prints the refs and reports them undetermined (exit 0), so the ref construction stays reviewable.
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1

# app | setup script | image | tag rule
#   keepv  = the deployed tag is the FALLBACK_VERSION verbatim
#   stripv = the script drops a leading 'v' to form the image tag (IMAGE_TAG="${VER#v}")
APPS=(
  "immich|archive-immich-setup.sh|ghcr.io/immich-app/immich-server|keepv"
  "paperless|archive-paperless-setup.sh|ghcr.io/paperless-ngx/paperless-ngx|stripv"
  "copyparty|archive-copyparty-setup.sh|copyparty/ac|stripv"
  "czkawka|archive-czkawka-setup.sh|jlesage/czkawka|keepv"
  "stirling|archive-stirling-setup.sh|stirlingtools/stirling-pdf|stripv"
  "docmost|archive-docmost-setup.sh|docmost/docmost|stripv"
  "kopia|archive-kopia-setup.sh|kopia/kopia|keepv"
)

fallback_of() { grep -E '^FALLBACK_VERSION="' "$1" | head -1 | sed -E 's/^FALLBACK_VERSION="([^"]*)".*/\1/'; }

names=(); images=(); tags=(); problems=0
hdr "Resolved fallback image refs (as each script would deploy on a failed lookup)"
for row in "${APPS[@]}"; do
  IFS='|' read -r app script image rule <<<"$row"
  if [[ ! -f "$script" ]]; then bad "$app: $script not found"; problems=1; continue; fi
  fb="$(fallback_of "$script")"
  if [[ -z "$fb" ]]; then warn "$app: no FALLBACK_VERSION pin (resolves latest / :latest) — nothing to audit."; continue; fi
  case "$rule" in stripv) tag="${fb#v}";; *) tag="$fb";; esac
  names+=("$app"); images+=("$image"); tags+=("$tag")
  printf '  %s%-12s%s %s:%s\n' "$C_CYN" "$app" "$C_RST" "$image" "$tag"
done

if ! command -v skopeo >/dev/null 2>&1; then
  warn "skopeo not installed — can't check the registries (its CI job installs it). Refs above are reviewable."
  exit "$problems"
fi

# tag_in_list <tag> reads a skopeo list-tags JSON on stdin; exit 0 iff the tag is present.
tag_in_list() { python3 -c 'import sys,json; sys.exit(0 if sys.argv[1] in (json.load(sys.stdin).get("Tags") or []) else 1)' "$1"; }

hdr "Checking each fallback tag exists upstream (skopeo list-tags)"
verified=0; undetermined=0
for i in "${!names[@]}"; do
  name="${names[$i]}"; image="${images[$i]}"; tag="${tags[$i]}"
  if taglist="$(skopeo list-tags "docker://$image" 2>/dev/null)"; then
    if printf '%s' "$taglist" | tag_in_list "$tag"; then
      ok "${name}: ${image}:${tag}"; verified=$((verified+1))
    else
      bad "${name}: ${image}:${tag} is NOT in the registry's tag list — fix FALLBACK_VERSION in its setup script."
      problems=1
    fi
  else
    warn "${name}: couldn't list tags for ${image} (no egress / rate-limited) — undetermined, not failing."
    undetermined=$((undetermined+1))
  fi
done

hdr "Summary"
if (( problems )); then
  bad "version/fallback audit FAILED — a pinned fallback tag is confirmed missing upstream."
elif (( undetermined > 0 )); then
  warn "${verified} fallback tag(s) verified; ${undetermined} undetermined (registry unreachable/rate-limited). Not failing."
else
  ok "all ${verified} fallback tags exist upstream."
fi
exit "$problems"
