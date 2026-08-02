#!/usr/bin/env bash
#
# openarchiver/backup-env.sh — prove the Open Archiver secrets are really backed up off the box,
# and that the backup is really the file it claims to be, WITHOUT ever printing a secret.
#
# THE RISK THIS ADDRESSES
#   /srv/apps/openarchiver/.env holds ENCRYPTION_KEY and STORAGE_ENCRYPTION_KEY. Neither can be
#   regenerated. Lose them and every message Open Archiver has stored becomes permanently
#   unreadable. That is the largest lockout risk in this stack, and it gets worse with every
#   mailbox imported — which is exactly why the check belongs BEFORE the big import, not after.
#   "I think I copied it" is not a backup, and a backup nobody has verified is a rumour.
#
# WHY A FINGERPRINT AND NOT A DIFF
#   The backup lives off the box on purpose, so nothing running here can see it. What this emits
#   instead is a digest-only MANIFEST: the sha256 of the file, and the sha256 of each secret VALUE
#   — never a value itself. The manifest can be carried to wherever the copy lives and checked
#   there. It is safe to paste into a chat log or a ticket; the .env is not.
#
# THE TRAP THIS IS BUILT AROUND
#   The usual way to fetch this file is
#       ssh HOST 'sudo cat /srv/apps/openarchiver/.env' > backup.txt
#   and the usual way it fails is silently: sudo wants a terminal, writes its complaint to stderr,
#   and leaves a ZERO-BYTE backup.txt behind. A check that only asks "does the file exist?" passes
#   on that. So `verify` refuses to look at existence alone: it requires content, structure, the
#   irreplaceable keys in the right shape, AND a digest match against a reference. Without a
#   reference it reports UNVERIFIED and exits non-zero rather than implying the copy is good.
#
# WHAT IT NEVER DOES
#   never writes anywhere under the app directory · never copies secrets to a temp file · never
#   prints a secret value (there is an output guard that aborts if one would slip through) ·
#   never reports a property it has not observed.
#
#   Read-only by nature, so there is no --go: the only thing it can write is a manifest file whose
#   path you name yourself, and it refuses to overwrite that.
#
# Usage
#   bash backup-env.sh                                     fingerprint the live .env
#   bash backup-env.sh fingerprint --manifest PATH         also save the digest-only manifest
#   bash backup-env.sh verify PATH                         on the box: compare to the live .env
#   bash backup-env.sh verify PATH --expect DIGEST         anywhere: compare to a pasted sha256
#   bash backup-env.sh verify PATH --manifest PATH         anywhere: compare to a saved manifest
#
set -uo pipefail

APP_DIR="${OPENARCHIVER_DIR:-/srv/apps/openarchiver}"
ENV_FILE="${OPENARCHIVER_ENV:-$APP_DIR/.env}"

# Losing either of these makes stored mail unreadable. There is no recovery, so they are checked
# hardest: present, non-empty, and 32 bytes rendered as 64 hex characters (upstream's requirement,
# and what archive-openarchiver-setup.sh generates).
CRITICAL_KEYS="ENCRYPTION_KEY STORAGE_ENCRYPTION_KEY"
# Losing these costs work — re-auth, a database password reset, a re-index — but not the archive.
IMPORTANT_KEYS="JWT_SECRET POSTGRES_PASSWORD MEILI_MASTER_KEY REDIS_PASSWORD"
# Non-secret markers. Their presence is what distinguishes a real .env from a captured error
# message, an HTML login page, or half a file.
MARKER_KEYS="NODE_ENV STORAGE_TYPE DATABASE_URL"

# Only `die` prints directly. Everything else is composed into $REPORT and printed through
# guarded_print, so that no user-facing line can bypass the secret-leak check on its way out.
c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
die(){ printf '%sFATAL%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 2; }

fails=0

# ------------------------------------------------------------------------------------------------
# Hashing. Chosen ONCE, up front, and fatal if absent — a missing hash tool must stop the run, not
# quietly reduce it to an existence check. sha256sum is GNU, shasum ships on macOS, openssl is the
# last resort; verification is expected to run on the Mac as often as on the box.
HASH_KIND=""
if command -v sha256sum >/dev/null 2>&1;  then HASH_KIND="sha256sum"
elif command -v shasum >/dev/null 2>&1;   then HASH_KIND="shasum"
elif command -v openssl >/dev/null 2>&1;  then HASH_KIND="openssl"
else die "no sha256 tool found (sha256sum, shasum or openssl). Cannot verify anything."
fi

sha_stream(){                       # hash stdin
  case "$HASH_KIND" in
    sha256sum) sha256sum | awk '{print $1}' ;;
    shasum)    shasum -a 256 | awk '{print $1}' ;;
    openssl)   openssl dgst -sha256 | awk '{print $NF}' ;;
  esac
}
sha_of_string(){ printf '%s' "$1" | sha_stream; }

# read_file — emit a file's bytes, escalating to sudo only if we cannot read it ourselves. The live
# .env is 0600 and root-owned, so on the box this normally needs sudo; a backup copy normally does
# not. Failure to read is fatal upstream, never a silent empty stream.
read_file(){
  if [ -r "$1" ]; then
    cat -- "$1"
  elif command -v sudo >/dev/null 2>&1; then
    sudo cat -- "$1"
  else
    return 1
  fi
}
# Hash from the STREAM, never from a shell variable: command substitution strips trailing newlines,
# which would change the digest and make every comparison wrong in a way that still looks tidy.
sha_of_file(){ read_file "$1" | sha_stream; }
bytes_of_file(){ read_file "$1" | wc -c | tr -d ' '; }
lines_of_file(){ read_file "$1" | wc -l | tr -d ' '; }

# value_of <content> <key> — the raw value, trailing CR included on purpose: a CRLF-mangled copy
# shows up as a 65-character "64 hex" key, which is a far more useful diagnosis than a bare
# digest mismatch.
value_of(){ printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

is_64_hex(){ case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }

# ------------------------------------------------------------------------------------------------
# Output guard. Everything user-facing is composed into a buffer, scanned for every secret value we
# read, and only then printed. If a value would appear in the output the script aborts instead —
# this output is meant to be pasteable off the box, and that promise has to be enforced, not
# intended. Values shorter than 8 characters are skipped (they would false-positive against
# ordinary words), and are separately reported as implausibly short secrets.
LEAK_MIN=8
declare -a SECRET_VALUES=()

guarded_print(){
  local text="$1" v
  for v in "${SECRET_VALUES[@]:-}"; do
    [ -n "$v" ] || continue
    [ "${#v}" -ge "$LEAK_MIN" ] || continue
    case "$text" in
      *"$v"*) die "INTERNAL: the report would have contained a secret VALUE. Refusing to print it.
    This is the output guard doing its job — the report is meant to be safe to paste off the box.
    Nothing was written or sent." ;;
    esac
  done
  printf '%s' "$text"
}

# ------------------------------------------------------------------------------------------------
# inspect_file <path> <label>
# Structural inspection of anything claiming to be an Open Archiver .env. Populates the globals
# below and appends its findings to REPORT. Returns non-zero if the file is not usable as a backup.
INS_BYTES=""; INS_LINES=""; INS_SHA=""; INS_CONTENT=""
declare -a INS_KEYNAMES=() INS_KEYDIGESTS=() INS_KEYLENS=()

inspect_file(){
  local path="$1" label="$2" k v d rc=0
  INS_BYTES=""; INS_LINES=""; INS_SHA=""; INS_CONTENT=""
  INS_KEYNAMES=(); INS_KEYDIGESTS=(); INS_KEYLENS=()

  if [ ! -e "$path" ]; then
    REPORT+="  FAIL  $label does not exist: $path"$'\n'
    return 1
  fi
  if [ ! -f "$path" ]; then
    REPORT+="  FAIL  $label is not a regular file: $path"$'\n'
    return 1
  fi
  if ! read_file "$path" >/dev/null 2>&1; then
    REPORT+="  FAIL  $label is not readable: $path"$'\n'
    REPORT+="        (the live .env is 0600 and root-owned — run this with sudo available)"$'\n'
    return 1
  fi

  INS_BYTES="$(bytes_of_file "$path")"
  # THE ZERO-BYTE TRAP. `ssh HOST 'sudo cat ...' > file` leaves exactly this behind when sudo needs
  # a terminal. Existence proves nothing; this is the check that would have caught it.
  if [ "${INS_BYTES:-0}" -eq 0 ]; then
    REPORT+="  FAIL  $label is EMPTY (0 bytes): $path"$'\n'
    REPORT+="        A zero-byte backup is the classic silent failure of"$'\n'
    REPORT+="          ssh HOST 'sudo cat ...' > file"$'\n'
    REPORT+="        when sudo could not prompt. The secrets were never copied. Re-run the fetch."$'\n'
    return 1
  fi

  INS_LINES="$(lines_of_file "$path")"
  INS_SHA="$(sha_of_file "$path")"
  INS_CONTENT="$(read_file "$path")"

  if [ -z "$INS_SHA" ]; then
    REPORT+="  FAIL  could not compute a digest for $label — refusing to guess."$'\n'
    return 1
  fi

  # Is this an Open Archiver .env at all, or something that merely landed in the file? A captured
  # "sudo: a terminal is required" or an HTML error page has none of these markers.
  local missing_markers=""
  for k in $MARKER_KEYS; do
    v="$(value_of "$INS_CONTENT" "$k")"
    [ -n "$v" ] || missing_markers="$missing_markers $k"
  done
  if [ -n "$missing_markers" ]; then
    REPORT+="  FAIL  $label does not look like an Open Archiver .env — missing:$missing_markers"$'\n'
    REPORT+="        First line seen: $(printf '%s\n' "$INS_CONTENT" | head -1 | cut -c1-60)"$'\n'
    REPORT+="        A captured error message or a truncated download looks exactly like this."$'\n'
    rc=1
  fi

  # Secret keys: present, non-empty, and — for the irreplaceable pair — the right shape.
  for k in $CRITICAL_KEYS $IMPORTANT_KEYS; do
    v="$(value_of "$INS_CONTENT" "$k")"
    SECRET_VALUES+=("$v")
    d=""
    [ -n "$v" ] && d="$(sha_of_string "$v")"
    INS_KEYNAMES+=("$k"); INS_KEYLENS+=("${#v}"); INS_KEYDIGESTS+=("${d:0:16}")

    local critical=0
    case " $CRITICAL_KEYS " in *" $k "*) critical=1 ;; esac

    if [ -z "$v" ]; then
      if [ "$critical" -eq 1 ]; then
        REPORT+="  FAIL  $k is MISSING or empty in $label — this key cannot be regenerated."$'\n'
        REPORT+="        Without it, every message already stored is permanently unreadable."$'\n'
        rc=1
      else
        REPORT+="  FAIL  $k is missing or empty in $label."$'\n'
        rc=1
      fi
      continue
    fi

    case "$v" in
      *$'\r'*)
        REPORT+="  FAIL  $k carries a trailing carriage return in $label — the copy was mangled"$'\n'
        REPORT+="        to CRLF in transit. Re-fetch it without passing through a Windows editor"$'\n'
        REPORT+="        or a terminal that rewrites line endings."$'\n'
        rc=1 ;;
    esac

    if [ "$critical" -eq 1 ] && ! is_64_hex "$v"; then
      REPORT+="  FAIL  $k is not 32 bytes of hex (expected 64 hex characters, got ${#v} characters)"$'\n'
      REPORT+="        in $label. Upstream requires 32 bytes and the installer generates exactly"$'\n'
      REPORT+="        that, so a different shape means this is not the file we think it is."$'\n'
      rc=1
    elif [ "${#v}" -lt "$LEAK_MIN" ]; then
      REPORT+="  FAIL  $k is implausibly short (${#v} characters) in $label — not a generated secret."$'\n'
      rc=1
    fi
  done

  return "$rc"
}

render_keytable(){
  local i n note
  REPORT+=$'\n'"$(printf '  %-24s %5s  %s' 'key' 'chars' 'value-sha256')"$'\n'
  n="${#INS_KEYNAMES[@]}"
  for (( i=0; i<n; i++ )); do
    note=""
    case " $CRITICAL_KEYS " in *" ${INS_KEYNAMES[$i]} "*) note="   <- IRREPLACEABLE" ;; esac
    REPORT+="$(printf '  %-24s %5s  %-16s%s' \
      "${INS_KEYNAMES[$i]}" "${INS_KEYLENS[$i]}" "${INS_KEYDIGESTS[$i]:-none}" "$note")"$'\n'
  done
}

# ------------------------------------------------------------------------------------------------
# Manifest — digests only, no values. Safe to keep next to the backup and safe to paste.
MANIFEST_PATH=""

manifest_text(){
  local i n
  printf '# openarchiver-env-manifest v1 — digests only, contains NO secret values\n'
  printf 'generated_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'source_host\t%s\n'   "$(hostname 2>/dev/null || echo unknown)"
  printf 'env_path\t%s\n'      "$ENV_FILE"
  printf 'bytes\t%s\n'         "$INS_BYTES"
  printf 'lines\t%s\n'         "$INS_LINES"
  printf 'sha256\t%s\n'        "$INS_SHA"
  n="${#INS_KEYNAMES[@]}"
  for (( i=0; i<n; i++ )); do
    printf 'key\t%s\t%s\t%s\n' "${INS_KEYNAMES[$i]}" "${INS_KEYLENS[$i]}" "${INS_KEYDIGESTS[$i]}"
  done
}

manifest_field(){ sed -n "s/^$2	//p" "$1" 2>/dev/null | head -1; }

# ------------------------------------------------------------------------------------------------
# diagnose <copy_path> <ref_path>
# A bare "digests differ" tells you nothing about what to do next. These four questions cover every
# way a copy of this file has plausibly gone wrong in transit.
diagnose(){
  local copy="$1" ref="$2" a b
  REPORT+=$'\n'"  Why they differ:"$'\n'

  local cb rb
  cb="$(bytes_of_file "$copy")"; rb="$(bytes_of_file "$ref")"
  if [ "${cb:-0}" -lt "${rb:-0}" ]; then
    a="$(read_file "$ref" | head -c "$cb" | sha_stream)"
    b="$(sha_of_file "$copy")"
    if [ "$a" = "$b" ]; then
      REPORT+="    TRUNCATED — the copy is the first $cb of $rb bytes and stops there."$'\n'
      REPORT+="    The transfer was cut off. Re-fetch it; do not try to repair this file."$'\n'
      return 0
    fi
  fi

  a="$(read_file "$copy" | tr -d '\r' | sha_stream)"
  b="$(read_file "$ref"  | tr -d '\r' | sha_stream)"
  if [ "$a" = "$b" ]; then
    REPORT+="    LINE ENDINGS — identical once carriage returns are removed. The copy went"$'\n'
    REPORT+="    through something that rewrote LF to CRLF. The VALUES are intact, but restore"$'\n'
    REPORT+="    from a clean re-fetch rather than trusting an editor to convert it back."$'\n'
    return 0
  fi

  a="$(read_file "$copy" | sed 's/[[:space:]]*$//' | sha_stream)"
  b="$(read_file "$ref"  | sed 's/[[:space:]]*$//' | sha_stream)"
  if [ "$a" = "$b" ]; then
    REPORT+="    TRAILING WHITESPACE only — the values are intact but the bytes differ."$'\n'
    return 0
  fi

  # Fall back to naming which KEYS differ. Names only — never values, never digests of the
  # reference side beyond what the manifest already carries.
  local rc rv cv k differ=""
  rc="$(read_file "$ref")"
  for k in $CRITICAL_KEYS $IMPORTANT_KEYS; do
    rv="$(value_of "$rc" "$k")"; cv="$(value_of "$INS_CONTENT" "$k")"
    SECRET_VALUES+=("$rv")
    [ "$rv" = "$cv" ] || differ="$differ $k"
  done
  if [ -n "$differ" ]; then
    REPORT+="    DIFFERENT SECRETS — these keys do not match the reference:$differ"$'\n'
    case "$differ" in
      *ENCRYPTION_KEY*)
        REPORT+="    An irreplaceable key differs. Either this backup predates a re-key, or it is"$'\n'
        REPORT+="    from a different install. Do NOT discard it — keep both, and work out which"$'\n'
        REPORT+="    one the stored mail was encrypted with before anything is overwritten."$'\n' ;;
    esac
  else
    REPORT+="    Every known secret matches; the difference is elsewhere in the file (comments,"$'\n'
    REPORT+="    ordering, or a non-secret setting). The keys themselves are intact."$'\n'
  fi
}

# ------------------------------------------------------------------------------------------------
mode_fingerprint(){
  REPORT="${c_b}== Open Archiver secrets — fingerprint of the LIVE .env${c_0}"$'\n'
  REPORT+=$'\n'"  file  : $ENV_FILE"$'\n'

  if ! inspect_file "$ENV_FILE" "the live .env"; then
    fails=$((fails+1))
    REPORT+=$'\n'"  ${c_r}The live .env is not in a state worth backing up. Fix it before importing mail.${c_0}"$'\n'
    guarded_print "$REPORT"
    return 1
  fi

  REPORT+="  bytes : $INS_BYTES"$'\n'
  REPORT+="  lines : $INS_LINES"$'\n'
  REPORT+="  sha256: $INS_SHA"$'\n'
  render_keytable
  REPORT+=$'\n'"  All ${#INS_KEYNAMES[@]} secrets are present and well-formed. Nothing above is a secret value —"$'\n'
  REPORT+="  the digests are one-way, so this block is safe to paste off the box."$'\n'

  if [ -n "$MANIFEST_PATH" ]; then
    if [ -e "$MANIFEST_PATH" ]; then
      REPORT+=$'\n'"  ${c_r}FAIL${c_0} refusing to overwrite an existing manifest: $MANIFEST_PATH"$'\n'
      fails=$((fails+1))
    elif manifest_text >"$MANIFEST_PATH" 2>/dev/null; then
      REPORT+=$'\n'"  manifest written: $MANIFEST_PATH  (digests only — no secrets)"$'\n'
    else
      REPORT+=$'\n'"  ${c_r}FAIL${c_0} could not write the manifest to $MANIFEST_PATH"$'\n'
      fails=$((fails+1))
    fi
  fi

  local who host
  who="$(id -un 2>/dev/null || echo user)"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo archive-pc)"

  REPORT+=$'\n'"${c_b}== Back it up now, then prove the copy${c_0}"$'\n'
  REPORT+=$'\n'"  1. ON THIS BOX, make a copy you own. Plain scp cannot read the original (0600, root),"$'\n'
  REPORT+="     and 'ssh HOST sudo cat ...' fails with \"a terminal is required to authenticate\""$'\n'
  REPORT+="     because sudo has no tty over a non-interactive ssh:"$'\n'
  REPORT+="$(printf '       sudo install -m 600 -o %s %s ~/openarchiver-env-backup.txt' "$who" "$ENV_FILE")"$'\n'
  REPORT+=$'\n'"     Do NOT reach for 'ssh -t' to get around that. A tty rewrites every LF to CRLF on"$'\n'
  REPORT+="     the way through, so the copy arrives corrupted. (This tool would catch it — the"$'\n'
  REPORT+="     digest fails and the diagnosis says LINE ENDINGS — but it is a wasted round trip.)"$'\n'
  REPORT+=$'\n'"  2. From your Mac, pull that copy down:"$'\n'
  REPORT+="$(printf '       scp %s@%s:~/openarchiver-env-backup.txt ~/openarchiver-env-backup.txt' "$who" "$host")"$'\n'
  REPORT+=$'\n'"  3. Check what actually arrived. This compares the copy against THIS box, so it catches"$'\n'
  REPORT+="     the empty file a failed fetch leaves behind:"$'\n'
  # shellcheck disable=SC2016  # the $(...) is part of the command being PRINTED for the operator to
  # paste; expanding it here would substitute this box's shell instead of theirs
  REPORT+="$(printf '       test "$(shasum -a 256 ~/openarchiver-env-backup.txt | cut -d" " -f1)" = "%s" && echo MATCH || echo MISMATCH' "$INS_SHA")"$'\n'
  REPORT+=$'\n'"     (on a Linux machine use sha256sum in place of shasum -a 256)"$'\n'
  REPORT+=$'\n'"  4. Once it MATCHES, remove the staging copy from this box — it is a plaintext key"$'\n'
  REPORT+="     file sitting in a home directory until you do:"$'\n'
  REPORT+="       rm ~/openarchiver-env-backup.txt"$'\n'
  REPORT+=$'\n'"  5. Store the copy somewhere that outlives this machine, and keep it as private as the"$'\n'
  REPORT+="     mailbox itself — it decrypts the archive. A second copy on separate media is not"$'\n'
  REPORT+="     paranoia here; there is no way to regenerate these two keys."$'\n'
  REPORT+=$'\n'"  Then, with the copy reachable from a shell:"$'\n'
  REPORT+="$(printf '       bash openarchiver/backup-env.sh verify ~/openarchiver-env-backup.txt --expect %s' "$INS_SHA")"$'\n'

  guarded_print "$REPORT"
}

mode_verify(){
  local copy="$1"
  REPORT="${c_b}== Open Archiver secrets — verifying a backup copy${c_0}"$'\n'
  REPORT+=$'\n'"  copy  : $copy"$'\n'

  local structural_ok=1
  inspect_file "$copy" "the backup copy" || structural_ok=0

  if [ -n "$INS_SHA" ]; then
    REPORT+="  bytes : $INS_BYTES"$'\n'
    REPORT+="  lines : $INS_LINES"$'\n'
    REPORT+="  sha256: $INS_SHA"$'\n'
    [ "${#INS_KEYNAMES[@]}" -gt 0 ] && render_keytable
  fi

  # Establish a reference. Structure alone can never be enough: a perfectly-formed .env from some
  # OTHER install would sail through every check above and decrypt nothing.
  local ref_sha="" ref_source="" ref_path=""
  if [ -n "$EXPECT_SHA" ]; then
    ref_sha="$EXPECT_SHA"; ref_source="the digest given on the command line"
  elif [ -n "$MANIFEST_PATH" ]; then
    if [ ! -s "$MANIFEST_PATH" ]; then
      REPORT+=$'\n'"  ${c_r}FAIL${c_0} manifest not found or empty: $MANIFEST_PATH"$'\n'
      fails=$((fails+1))
    else
      ref_sha="$(manifest_field "$MANIFEST_PATH" sha256)"
      ref_source="the manifest $MANIFEST_PATH"
      [ -n "$ref_sha" ] || { REPORT+=$'\n'"  ${c_r}FAIL${c_0} no sha256 line in $MANIFEST_PATH"$'\n'; fails=$((fails+1)); }
    fi
  elif read_file "$ENV_FILE" >/dev/null 2>&1; then
    ref_sha="$(sha_of_file "$ENV_FILE")"; ref_source="the live .env on this box"; ref_path="$ENV_FILE"
  fi

  # Structural problems are counted here, but they deliberately do NOT short-circuit the
  # comparison. "This copy is the first 200 bytes of the reference" is the most actionable sentence
  # the tool can produce, and it is only reachable by comparing — bailing out early would bury it
  # under a wall of missing-key failures that all have the same single cause.
  if [ "$structural_ok" -eq 0 ]; then fails=$((fails+1)); fi

  REPORT+=$'\n'
  if [ -z "$ref_sha" ]; then
    # The single most important refusal in this script: no reference means nothing has been
    # verified, and saying so is the only honest outcome.
    REPORT+="  ${c_r}UNVERIFIED${c_0} — there is nothing to compare this copy against."$'\n'
    REPORT+="  Structure was checked, but structure cannot tell a good backup from a valid .env"$'\n'
    REPORT+="  belonging to a different install. Re-run with the digest from the box:"$'\n'
    REPORT+="       bash openarchiver/backup-env.sh verify $copy --expect DIGEST"$'\n'
    REPORT+="  (get DIGEST by running 'bash openarchiver/backup-env.sh fingerprint' on the box)"$'\n'
    fails=$((fails+1))
  elif [ "$INS_SHA" = "$ref_sha" ] && [ "$structural_ok" -eq 1 ]; then
    REPORT+="  ${c_g}VERIFIED${c_0} — byte-identical to $ref_source."$'\n'
    REPORT+="  The irreplaceable keys are present, well-formed, and safe off the box."$'\n'
    REPORT+="  This is the gate that had to pass before a large import. It has passed."$'\n'
  elif [ "$INS_SHA" = "$ref_sha" ]; then
    # A faithful copy of a broken original. Worth separating loudly: re-fetching will not help.
    REPORT+="  ${c_r}FAIL${c_0} the copy is byte-identical to $ref_source — but that file is itself"$'\n'
    REPORT+="  malformed (see the failures above). The COPY is faithful; the ORIGINAL is the"$'\n'
    REPORT+="  problem. Re-fetching will not fix it."$'\n'
  else
    REPORT+="  ${c_r}MISMATCH${c_0} — the copy is NOT what $ref_source describes."$'\n'
    REPORT+="    copy     : $INS_SHA"$'\n'
    REPORT+="    reference: $ref_sha"$'\n'
    fails=$((fails+1))
    if [ -n "$ref_path" ]; then
      diagnose "$copy" "$ref_path"
    elif [ -n "$MANIFEST_PATH" ] && [ -s "$MANIFEST_PATH" ]; then
      # Off the box we have no reference file, but the manifest carries per-key digests — enough
      # to name which secrets differ without ever holding the other side's values.
      local i n mk ml md differ="" line
      REPORT+=$'\n'"  Why they differ (from the manifest):"$'\n'
      n="${#INS_KEYNAMES[@]}"
      for (( i=0; i<n; i++ )); do
        line="$(grep -F "	${INS_KEYNAMES[$i]}	" "$MANIFEST_PATH" 2>/dev/null | head -1)"
        mk="$(printf '%s' "$line" | cut -f2)"; ml="$(printf '%s' "$line" | cut -f3)"; md="$(printf '%s' "$line" | cut -f4)"
        [ -n "$mk" ] || continue
        if [ "$md" != "${INS_KEYDIGESTS[$i]}" ]; then
          differ="$differ ${INS_KEYNAMES[$i]}"
          [ "$ml" = "${INS_KEYLENS[$i]}" ] || \
            REPORT+="    ${INS_KEYNAMES[$i]}: manifest says $ml characters, this copy has ${INS_KEYLENS[$i]}"$'\n'
        fi
      done
      if [ -n "$differ" ]; then
        REPORT+="    DIFFERENT SECRETS —$differ"$'\n'
        case "$differ" in
          *ENCRYPTION_KEY*)
            REPORT+="    An irreplaceable key differs. Keep both copies and establish which one the"$'\n'
            REPORT+="    stored mail was encrypted with before anything is overwritten."$'\n' ;;
        esac
      else
        REPORT+="    Every secret digest matches the manifest; the difference is elsewhere in the"$'\n'
        REPORT+="    file. The keys themselves are intact."$'\n'
      fi
    else
      REPORT+=$'\n'"    Only a digest was given, so the difference cannot be localised from here."$'\n'
      REPORT+="    Re-run on the box, or pass --manifest, to find out which keys differ."$'\n'
    fi
  fi

  guarded_print "$REPORT"
}

# ------------------------------------------------------------------------------------------------
MODE=""; TARGET=""; EXPECT_SHA=""; REPORT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    fingerprint|verify) MODE="$1" ;;
    --manifest) shift; MANIFEST_PATH="${1:-}"; [ -n "$MANIFEST_PATH" ] || die "--manifest needs a path" ;;
    --expect)   shift; EXPECT_SHA="${1:-}";    [ -n "$EXPECT_SHA" ]    || die "--expect needs a sha256" ;;
    -h|--help)  sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          TARGET="$1" ;;
  esac
  shift
done
[ -n "$MODE" ] || MODE="fingerprint"

if [ -n "$EXPECT_SHA" ]; then
  case "$EXPECT_SHA" in
    *[!0-9a-fA-F]*) die "--expect is not a hex digest: $EXPECT_SHA" ;;
  esac
  [ "${#EXPECT_SHA}" -eq 64 ] || die "--expect must be a full 64-character sha256 (got ${#EXPECT_SHA})"
  EXPECT_SHA="$(printf '%s' "$EXPECT_SHA" | tr 'A-F' 'a-f')"
fi

case "$MODE" in
  fingerprint)
    [ -n "$TARGET" ] && ENV_FILE="$TARGET"
    mode_fingerprint ;;
  verify)
    [ -n "$TARGET" ] || die "usage: ${0##*/} verify PATH [--expect DIGEST | --manifest PATH]"
    mode_verify "$TARGET" ;;
esac

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '  %sPASS%s\n' "$c_g" "$c_0"
else
  printf '  %s%d check(s) FAILED — the secrets are NOT provably backed up.%s\n' "$c_r" "$fails" "$c_0"
  printf '  %sDo not start a large import until this passes: every message imported before the\n' "$c_y"
  printf '  keys are safe is a message that becomes unreadable if this box dies.%s\n' "$c_0"
fi
exit "$fails"
