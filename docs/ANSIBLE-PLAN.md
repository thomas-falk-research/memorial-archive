# Ansible Migration Plan — memorial-archive

> **Status:** planning only. Nothing in this document is implemented yet. It is the design and
> role-by-role work map for introducing Ansible as the configuration-management layer of the
> memorial-archive server, without reinventing or endangering the parts of the system that already
> work.
>
> **Scope of this branch (`claude/ansible-config-management`):** design and reference only. The bash
> system remains the shipping product on `main`; this plan is what we execute against when we decide
> to build.

---

## 0. TL;DR — the decision

Adopt Ansible, but **not** as a parallel/mirrored copy of the bash system. A second full
implementation would recreate the exact config-drift problem we are trying to escape — now doubled
across two sources of truth that must be hand-synchronised.

Instead, split the repo along a seam that already exists in the code:

| Layer | What it is | Where it goes |
|---|---|---|
| **A — Configuration management** | package installs, locale, SSH hardening, ufw, unattended-upgrades, Docker, Tailscale, fstab mounts, systemd units, Samba/Caddy/Compose/`.env` templating, secrets | **Ansible roles** |
| **B — Domain logic** | write-blocking `safe-mount`, checksum-verified `ingest-verify`/`archive-verify`, the verified backup engine, the interactive menus, `archive-doctor`, `archive-selftest`, USB imaging | **stays bash; Ansible only deploys it** |

Ansible replaces the *provisioning* half of every `*-setup.sh` (the `apt`/`tee`/`systemctl`/`mkdir`
plumbing) and leaves the *irreplaceable* half (the safety-critical runtime logic embedded in the
installed commands) exactly as-is. The family never touches Ansible — it is an operator/admin tool,
run by the remote administrator over Tailscale+SSH, exactly where Ansible is strongest.

**Payoff (the three reasons this was raised):**
1. **Config drift** → one inventory (`group_vars` + vault) becomes the single source of truth.
2. **Rebuild / new PC / start over** → `ansible-playbook site.yml` against a fresh host reproduces
   the entire box, hardened, from that one source.
3. **Hardening without maintaining our own solutions** → `ansible-vault` replaces `chmod 600`
   plaintext secret files; battle-tested modules replace hand-written `grep -q` idempotency guards.

**Honest caveat:** with a single working box, Ansible's payoff is realised at *rebuild time*, not
day-to-day. That means we make Ansible the **primary** provisioning path and retire the
`provision.sh` plumbing as roles reach parity — we do **not** keep an unexercised parallel copy that
silently rots. A CI job that provisions a throwaway box from the playbook keeps "it still builds a
box" continuously proven.

---

## 1. Guiding principles

1. **One source of truth.** `/etc/archive-ingest.conf` is read by every script and every installed
   command today. In the Ansible world it becomes `group_vars/all.yml` (+ `vault.yml`), and Ansible
   *renders* `/etc/archive-ingest.conf` from those vars. The bash commands keep reading that file
   unchanged — this is the bridge that lets Layer B stay untouched.
2. **Ansible deploys the domain commands; it never reimplements them.** The bodies of `safe-mount`,
   `ingest-verify`, `archive-verify`, `archive`, `archive-index`, `archive-search`, `archive-find`,
   `archive-storage`, `archive-backup`, `archive-restic`, `archive-credentials`, `archive-apps`,
   `archive-pc-backup`, `archive-webui-run` are pure payload. They ship as files and are copied into
   `/usr/local/bin`. Their internal logic is out of scope for Ansible forever.
3. **Prefer declarative pinning over runtime resolution.** Several scripts resolve "latest" at
   install time (Go version from `go.dev`, app image tags via `git ls-remote`/Docker Hub API). We
   move those to **pinned variables** in the inventory. This is a reproducibility *win*: two builds
   a month apart produce the same box. The existing `FALLBACK_VERSION` values become the pinned
   defaults; `ci/version-audit.sh` continues to guard that those tags still exist upstream.
4. **The safety invariants are machine-checked and must survive the migration.** Read-only archive
   mounts, loopback-only app binds, `nofail` fstab, the udev no-automount rule, `0600` unrecoverable
   secrets, additive+verified backups, OCR search of the scanned will. These are already asserted by
   `ci/validate-compose.py`, `archive-doctor.sh`, and the roundtrip drills — we keep those as the
   acceptance gates (see §8).
5. **Incremental, parity-gated migration.** No big-bang rewrite. One role at a time, each proven
   against `archive-doctor` / `archive-selftest` / the roundtrips before the next begins (§9).
6. **Two parity oracles already exist.** `archive-doctor.sh` (observable end state, exit 0/1) and
   `archive-selftest.sh` (the installed tools actually enforce their guarantees). Both are
   implementation-agnostic — they inspect the box, not the installer — so they validate an
   Ansible-built host with zero changes.

---

## 2. Prerequisite refactor (do this in the bash repo first — no-regret)

Today each command is embedded in its setup script as a `sudo tee /usr/local/bin/<cmd> <<'SCRIPT'`
heredoc. CI already has to *extract* those bodies to lint and test them
(`ci/lib.sh:extract_embedded_commands`, which writes `<setup>__<cmd>.sh`).

**Before any Ansible work, promote the embedded commands to real files** in the bash repo, e.g.:

```
commands/
  safe-mount            ingest-verify         archive-verify        archive
  archive-index         archive-search        archive-find
  archive-storage       archive-backup        archive-restic        archive-credentials
  archive-apps          archive-pc-backup     archive-webui-run
```

Each setup script then `install`s its file instead of heredoc-ing it. Benefits **both** worlds:
- shellcheck/CI lint the real file directly (no extraction hack);
- the diff of a command change is readable;
- Ansible's `ansible.builtin.copy` deploys the identical artifact the bash path uses — **one source
  for the command bodies, so the two provisioning paths can never drift on the domain logic.**

This single refactor is what makes "Ansible and bash coexist during migration" safe rather than a
drift trap.

---

## 3. Target repository layout

```
ansible/
  ansible.cfg                     # roles_path, inventory, vault settings, ssh args
  site.yml                        # master play: base + selected roles, ordered
  requirements.yml                # collections: community.general, community.docker,
                                  #   ansible.posix, community.crypto
  inventory/
    hosts.yml                     # the box(es); connection = ssh over tailnet (or local for pull)
    group_vars/
      all.yml                     # THE single source of truth (non-secret) — renders
                                  #   /etc/archive-ingest.conf; pinned versions; ports; toggles
      all/vault.yml               # ansible-vault: every secret (see §6)
    host_vars/
      <hostname>.yml              # per-box specifics: disk UUIDs, backup share, tailnet name
  roles/
    base/                         # <- provision.sh
    ingest/                       # <- archive-ingest-setup.sh   (deploys 4 commands + conf + udev)
    search/                       # <- archive-search-setup.sh   (deploys 3 commands)
    serve/                        # <- archive-serve-setup.sh     (samba)
    storage/                      # <- archive-storage-setup.sh   (mounts + 2 commands + motd)
    restic/                       # <- archive-restic-setup.sh
    credentials/                  # <- archive-credentials-setup.sh (deploys 1 command)
    apps_common/                  # shared: docker network, /srv/apps, archive-apps command
    app_immich/  app_paperless/  app_copyparty/  app_czkawka/
    app_stirling/ app_docmost/   app_kopia/
    proxy/                        # <- archive-proxy-setup.sh     (caddy + portal + conf.d)
    webui/                        # <- archive-webui-setup.sh     (recoll web UI, systemd)
  files/
    commands/                     # the promoted command bodies from §2 (shared with bash repo)
  molecule/ or ci/provision/      # fresh-container acceptance harness (see §8)
```

**Kept as bash, outside Ansible entirely** (Layer B, imaging, validation):
`make-ubuntu-usb.sh`, `archive-doctor.sh`, `archive-selftest.sh`, `archive-reset.sh`, `manage.sh`,
and the whole `ci/` tree. `manage.sh` may gain an "Ansible" menu entry that shells out to
`ansible-playbook`, but its role as the family-facing menu is unchanged.

---

## 4. The variable model — how the single source of truth works

`/etc/archive-ingest.conf` is consumed by: `archive-storage`, `archive-restic`, `archive-credentials`,
`archive-serve`, `archive-search`, `archive-ingest`, `archive-doctor`, and more. It is the seam.

**Design:** `group_vars/all.yml` holds the canonical values; the `ingest` role renders
`/etc/archive-ingest.conf` from a Jinja2 template. Every installed bash command keeps reading that
file at runtime, so **nothing downstream changes**.

| `/etc/archive-ingest.conf` key | Default | Ansible var (`group_vars/all.yml`) |
|---|---|---|
| `ARCHIVE_ROOT` | `/srv/archive` | `archive_root` |
| `BACKUP_ROOT` | `/srv/backup` | `backup_root` |
| `INGEST_MNT` | `/mnt/ingest` | `ingest_mnt` |
| `APPS_ROOT` | `/srv/apps` | `apps_root` |
| `MAX_ARCHIVE_GIB` | `1800` | `max_archive_gib` |
| `MIN_FREE_GIB` | `10` | `min_free_gib` |
| `REQUIRE_SEPARATE_BACKUP` | `true` | `require_separate_backup` |
| `REQUIRE_MOUNTED_DEST` | `true` | `require_mounted_dest` |
| `BACKUP_APPS` | `true` | `backup_apps` |
| `BACKUP_STALE_DAYS` | `30` | `backup_stale_days` |
| `BASE_DOMAIN` | `home` | `base_domain` |
| `SHARE_NAME` | `archive` | `samba_share_name` |
| `RESTIC_KEEP_LAST/DAILY/WEEKLY/MONTHLY` | `3/7/5/12` | `restic_keep.{last,daily,weekly,monthly}` |
| `RESTIC_PASSWORD_FILE` | `/etc/archive-restic.pass` | `restic_password_file` |

Pinned versions (formerly runtime-resolved) live in the same file:

```yaml
versions:
  immich:    v2.7.5           # was git ls-remote → FALLBACK v2.7.5
  paperless: v2.20.15
  copyparty: v1.20.16
  czkawka:   v26.03.1         # was Docker Hub tags API
  stirling:  v2.12.0
  docmost:   v0.90.1
  postgres:  "16-alpine"      # docmost DB — pinned MAJOR, never bump on an existing DB
  redis:     "7-alpine"
  kopia:     0.18.2           # the only one that could fall through to :latest today — now pinned
  recoll_webui_commit: 127f849ae4bb4a690908ffef62cfb2d43784862d
  go:        "<pin>"          # replace provision.sh's go.dev runtime lookup
```

Per-box facts (disk identities, off-site share, tailnet) go in `host_vars/<hostname>.yml`:

```yaml
archive_disk_uuid:  "…"       # the 2 TB external NVMe
backup_target:                # exactly one of:
  kind: nfs|cifs|disk
  source: "nas:/export/archive"      # nfs export, //host/share, or UUID
tailnet_name: "…"
```

---

## 5. Secrets model — ansible-vault replaces `chmod 600` plaintext

Every secret the system generates today, and where it lives now:

| Secret | Current location | Vault key | Never-rotate? |
|---|---|---|---|
| restic repo passphrase | `/etc/archive-restic.pass` (0600) | `vault_restic_passphrase` | **yes** — rotating orphans all snapshots |
| Samba `family` password | Samba passdb (tdb) | `vault_samba_password` | no (resettable via smbpasswd) |
| Caddy `family`/search auth | bcrypt hash in Caddyfile | `vault_search_password_hash` | store the **hash**, not plaintext |
| Immich `DB_PASSWORD` | `/srv/apps/immich/.env` (0600) | `vault_immich_db_password` | yes (Postgres role) |
| Paperless `SECRET_KEY` | `.paperless-secret` (0600) | `vault_paperless_secret_key` | yes |
| Paperless admin password | Paperless DB | `vault_paperless_admin_password` | no (changepassword) |
| Docmost `APP_SECRET` | `/srv/apps/docmost/.env` (0600) | `vault_docmost_app_secret` | yes (invalidates sessions) |
| Docmost `DB_PASSWORD` | same `.env` | `vault_docmost_db_password` | yes (Postgres role) |
| Kopia repo password | `/srv/apps/kopia/.env` (0600) | `vault_kopia_repo_password` | **yes** — encrypts the repo |
| Kopia server-control password | same `.env` | `vault_kopia_control_password` | no |
| Kopia per-PC passwords | Kopia server ACLs | `vault_kopia_pc_passwords` (map) | no |
| Backup share (CIFS) credentials | `/etc/archive-backup.cred` (0600) | `vault_backup_cred` | no |
| Machine sudo password | Linux passwd | — | not managed by Ansible |
| Host SSH key | `~/.ssh/id_ed25519` | generate on host, not vaulted | — |

**How "never rotate on re-run" maps to Ansible.** Today the scripts read the existing `.env`/pass
file and reuse it (`sed -n 's/^KEY=//p'`, `sudo test -s`). In Ansible the vault **is** the single
source: the value is written once, and re-running the play renders the same value. Changing a
password becomes a deliberate edit of the vault — which is exactly the safety property we want.
Files are still emitted at `0600` (the `template`/`copy` `mode:`), so `archive-doctor`'s permission
checks and `archive-credentials`' reset guidance keep working. `archive-credentials` remains the
human-facing "where does each secret live and how do I reset it" reference, unchanged.

**Vault key management (decision needed, §11):** simple passphrase, or `sops`+`age` for a nicer
multi-key story. Recommendation: start with a single vault passphrase kept off-box in the operator's
password manager (same discipline the current "RECORD THIS NOW" banners already teach).

---

## 6. Role-by-role migration map

Legend: **→** = becomes this Ansible module/approach. Line refs are to the current scripts.
Everything under "**Stays bash**" ships as a file (from §2) and is deployed with `copy`, never
reimplemented.

### 6.1 `base` ← `provision.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L62-67, 181-182, 199, 209, 218, 309, 345, 351 | apt packages (base, docker, tailscale, gh, openssh, unattended-upgrades, ufw) | `ansible.builtin.apt` (grouped lists) |
| L103-166 | GPG keyrings + deb822 `.sources` for docker/tailscale/github-cli | `ansible.builtin.deb822_repository` (native; drops the curl+tee+keyring dance) |
| L69-80 | locale `en_US.UTF-8` | `community.general.locale_gen` + `ansible.builtin.command: update-locale` |
| L181-183 | Docker Engine + Compose v2 + enable service | apt via docker repo + `ansible.builtin.systemd_service` (or the `community.docker` install pattern) |
| L185-191 | add user to `docker` group | `ansible.builtin.user` (`groups: docker`, `append: true`) |
| L199-200 | Tailscale install + `tailscaled` enable | apt + `systemd_service`; `tailscale up` stays a **manual** post-step (needs interactive auth) |
| L282-284 | `/etc/profile.d/go.sh` | `ansible.builtin.template` |
| L314-331 | SSH hardening drop-in `99-hardening.conf` | `ansible.builtin.template` with `validate: "sshd -t -f %s"`; handler restarts `ssh` |
| L333-337 | ed25519 SSH keypair | `community.crypto.openssh_keypair` (or `user: generate_ssh_key`) |
| L344-347 | unattended-upgrades `20auto-upgrades` | `ansible.builtin.copy`/template |
| L349-359 | ufw default-deny + allow SSH + `tailscale0` | `community.general.ufw` (rules + `state: enabled`) |
| L247-286 | Go tarball, **runtime** version + checksum | `ansible.builtin.get_url` (checksum) + `unarchive`, version **pinned** in `versions.go` |
| L232-242 | Rust via rustup | `community.general.pipx`-style shell task **iff the box actually needs Rust** (see §11) |
| L291-302 | Chromium snap | `community.general.snap` — **evaluate necessity** on a headless archive box |
| L216-227 | pipx + Ansible on the host | **drop** on managed hosts (Ansible runs from control node); keep only if using `ansible-pull` (§11) |

**Stays bash / becomes pinned:** `resolve_suite()` apt-suite probing (L85-94) and the Go
version/checksum resolution (L257-277) are replaced by **pinned vars** — a reproducibility upgrade.
`sshd -t` validate-and-revert becomes the module's `validate:`.

**Handlers:** `restart ssh`, `restart docker`. **Tags:** `base`.

### 6.2 `ingest` ← `archive-ingest-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L33-42, 157-169 | `CORE_PKGS` + best-effort filesystem tools | `ansible.builtin.apt`; best-effort list in a second task with `failed_when: false` |
| L176-181 | `bagit` via pipx | `community.general.pipx` |
| L236-242 | udev `99-archive-no-automount.rules` | `ansible.builtin.copy` + handler `udevadm control --reload-rules && udevadm trigger` |
| L803-820 | **`/etc/archive-ingest.conf`** | `ansible.builtin.template` from `group_vars` — **the single-source bridge (§4)** |
| L822-823 | `/srv/archive/{incoming,images}`, `/mnt/ingest`, ownership | `ansible.builtin.file` (state=directory, owner/group = the operator user) |
| L220-224 | GNOME gsettings automount off | `community.general.dconf` (gate on desktop present) |
| L249-797 | `safe-mount`, `ingest-verify`, `archive-verify`, `archive` | `ansible.builtin.copy` from `files/commands/` (mode 0755) |
| L186-214 | APFS-fuse **source compile** (optional) | keep as a `block` (git + cmake/make) guarded by `creates:`, gated on `install_apfs` var |

**Stays bash (Layer B — never Ansible):** the block-layer write-block (`blockdev --setro` +
re-verify, L383-391), protected-disk refusal (L281-302), the SHA-256 completeness gate and
`.INCOMPLETE` lifecycle (L508-619), provenance, the interactive `archive` menu. Ansible ships these
files; their logic is untouchable.

**Tags:** `ingest`. **Note:** must run before `search`/`serve` (they require `ARCHIVE_ROOT` to exist).

### 6.3 `search` ← `archive-search-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L31-33, 91-98 | recoll/plocate/pst-utils/tesseract + best-effort | `ansible.builtin.apt` (+ `failed_when: false` list) |
| L103-273 | `archive-index`, `archive-search`, `archive-find` | `ansible.builtin.copy` from `files/commands/` |

**Stays bash:** PST/OST `.derived` extraction, OCR trigger logic, index scoping/pruning, `recollq`
reformatting (L136-247). **Important:** `recoll.conf` is generated **at run time** by `archive-index`
(L182-191), *not* at install time — Ansible does **not** template it. No secrets, no systemd.
**Tags:** `search`.

### 6.4 `serve` ← `archive-serve-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L82-83 | `samba` | `ansible.builtin.apt` |
| L133-136 | system user `family` (nologin, no home) | `ansible.builtin.user` |
| L86-114 | `/etc/samba/archive-share.conf` | `ansible.builtin.template` (share name, path, force user/group, veto list) |
| L66-67 | force user/group = `stat` of serve path | `ansible.builtin.stat` + `set_fact` (or set explicitly in vars) |
| L117-122 | `include = …` line into `smb.conf` | `ansible.builtin.lineinfile` (with backup) |
| L124-129 | testparm validate before restart | validation task; handler `restart smbd` only after `testparm -s` passes |
| L143-154 | Samba password (generate/set/enable) | task running `smbpasswd -a -s` from `vault_samba_password`, guarded by `pdbedit -L` so it never rotates an existing account |
| L162-165 | `ufw allow Samba` | `community.general.ufw` |

**Stays bash-flavoured:** the `veto files` list (hides `.INCOMPLETE`/`SHA256SUMS`/`PROVENANCE.txt`/
`*.ingest.log`) is domain knowledge but lives fine as static template content. **Handlers:**
`restart smbd`. **Tags:** `serve`.

### 6.5 `storage` ← `archive-storage-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L65-66 | `nfs-common cifs-utils rsync` | `ansible.builtin.apt` |
| L71-445, 448-602 | `archive-backup`, `archive-storage` | `ansible.builtin.copy` from `files/commands/` |
| L612-661 | MOTD banner `50-memorial-archive` | `ansible.builtin.template` (mode 0755) |
| fstab (written today at run time by `archive-storage attach-*`, L528-587) | archive + backup mounts with `nofail`, `x-systemd.*` | `ansible.posix.mount` driven from `host_vars` (UUID / NFS export / CIFS share) |
| L581-586 | `/etc/archive-backup.cred` (0600) | `ansible.builtin.template` (mode 0600) from `vault_backup_cred` |
| *(none today)* | scheduled backup | **opportunity:** add a `systemd` timer for `archive-backup` (+`archive-restic`) instead of hand-rolled cron |

**Hybrid on disk attach:** picking *which physical disk* is a human decision — keep the interactive
`archive-storage attach-archive/attach-backup` bash helper for first-time discovery. Once the UUID
is known, record it in `host_vars` and let `ansible.posix.mount` own the fstab entry declaratively.
Best of both: safe discovery, reproducible state.

**Stays bash (Layer B):** the verified backup engine — additive rsync, per-destination
`sha256sum -c` re-verification, completeness (manifest-count) check, the **same-disk refusal** safety
check (L339-350), and the best-effort app-data dumps (L181-330). **Tags:** `storage`.

### 6.6 `restic` ← `archive-restic-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L74-75 | `restic` | `ansible.builtin.apt` |
| L87-93 | passphrase file `/etc/archive-restic.pass` (0600) | `ansible.builtin.copy`/template (mode 0600) from `vault_restic_passphrase` |
| L96-208 | `archive-restic` | `ansible.builtin.copy` from `files/commands/` |
| *(none today)* | scheduling | optional `systemd` timer |

**Stays bash:** `do_backup` (backup→forget/prune→check, retention, same-disk refusal, verified
marker). The passphrase is now sourced from vault — the "never rotate / would orphan snapshots"
invariant is enforced by vault being the single source. **Tags:** `restic`.

### 6.7 `credentials` ← `archive-credentials-setup.sh`

Trivial: no packages, no secrets, no services. `ansible.builtin.copy` of the `archive-credentials`
reference command (mode 0755). Always deployed (it is the family's lockout lifeline). **Tags:**
`credentials`, and it should run in the default set unconditionally.

### 6.8 `apps_common` ← `archive-apps-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L68-73 | shared `memorial` docker network | `community.docker.docker_network` (the apps declare it `external: true`) |
| L76-138 | `archive-apps` management command | `ansible.builtin.copy` from `files/commands/` |
| — | `/srv/apps` | `ansible.builtin.file` |

The "each app keeps its own Compose project (never merge — avoids volume re-prefixing)" invariant is
preserved: one Ansible role per app, each calling `community.docker.docker_compose_v2` with its own
`project_src`. **Tags:** `apps`.

### 6.9 App roles — `app_immich` / `app_paperless` / `app_copyparty` / `app_czkawka` / `app_stirling` / `app_docmost` / `app_kopia`

Common shape per app role:
1. `ansible.builtin.file` — `/srv/apps/<app>` and its subdirs, owner = operator uid:gid.
2. `ansible.builtin.template` — `compose.yml` (+ `override.yml`) and `.env`.
3. `community.docker.docker_compose_v2` — `state: present` (brings the stack up; idempotent).
4. Handlers: recreate on template change.

Per-app specifics (all versions **pinned via `versions.*`**, replacing runtime resolution):

- **`app_immich`** (port 2283; `photos.<domain>`): **vendor** Immich's upstream `docker-compose.yml`
  for the pinned tag into the role (reviewable, offline-capable) instead of the current curl
  download (L86-88); template the **`docker-compose.override.yml`** that bind-mounts
  `${archive_root}:/mnt/archive:ro` (L113-119 — the **read-only** safety mount). `.env` from
  `vault_immich_db_password`.
- **`app_paperless`** (port 8000; `docs.<domain>`): vendor upstream `docker-compose.postgres.yml` +
  `docker-compose.env`; template the override that **pins** the image (upstream ships `:latest`) and
  maps the port (L143-150). Secrets `vault_paperless_secret_key`, `vault_paperless_admin_password`.
- **`app_copyparty`** (127.0.0.1:3923; `files.<domain>`): compose with `${archive_root}:/w/archive:ro`
  **and** `cfg/copyparty.conf` granting `r:` only — the documented 4-layer read-only defence
  (`:ro` bind + `r` ACL + loopback bind + cache off-archive). No secrets.
- **`app_czkawka`** (127.0.0.1:5800; `dupes.<domain>`): `${archive_root}:/storage:ro`, joins
  `memorial`. Version was Docker Hub date-tag → pinned. No secrets.
- **`app_stirling`** (127.0.0.1:8082; `pdf.<domain>`): **no archive mount at all** (upload-only);
  joins `memorial`. No secrets. `ci/validate-compose.py` already asserts this app never mounts the
  archive — keep that check.
- **`app_docmost`** (127.0.0.1:3000; `docmost.<domain>`): the only **read-write** app — app + `db`
  (`postgres:16-alpine`, pinned major) + `redis` (`7-alpine`), named volumes. Secrets
  `vault_docmost_app_secret`, `vault_docmost_db_password`. Its DB/uploads are the family's
  irreplaceable content — ensure `backup_apps` covers it (it does, via `archive-backup`).
- **`app_kopia`** (port 51515; PC-backup server): the most imperative app.
  - TLS cert (self-signed, 10y, dynamic SAN of host / `.local` / LAN IP / tailnet name, L109-121) →
    `community.crypto.openssl_privatekey` + `community.crypto.x509_certificate`, SAN built from Ansible
    facts (`ansible_hostname`, `ansible_default_ipv4.address`, tailnet var). Fingerprint via a
    `command` task (clients pin it).
  - `/srv/pc-backups/repo` on the **internal** disk (read-write backup target, off the archive
    budget) → `ansible.builtin.file`.
  - First-run repo init (`docker compose run --rm … repository create`, L170) + `server acl enable`
    → `community.docker.docker_container`/`command` guarded by a `creates:` on
    `config/repository.config`.
  - Secrets `vault_kopia_repo_password` (never rotate — encrypts the repo), `vault_kopia_control_password`.
  - `archive-pc-backup` command → `ansible.builtin.copy`. Per-PC user provisioning (`kopia server
    user add`) stays in that command; per-PC passwords can be seeded from `vault_kopia_pc_passwords`.

**Read-only invariant (non-negotiable):** every archive bind mount in every app template is `:ro`.
`ci/validate-compose.py` (L159-165) renders these templates and fails CI on any archive mount that
isn't read-only or any "must-not-touch-archive" app that mounts it. We extend that script to render
the **Ansible-templated** compose (see §8) so the check protects both provisioning paths.

**Tags:** `apps` plus a per-app tag (`immich`, `paperless`, …) to mirror the current pick-and-choose
menu.

### 6.10 `proxy` ← `archive-proxy-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L107 | Caddy via apt | `ansible.builtin.apt` (add Caddy repo via `deb822_repository`) |
| L279-391 | `/etc/caddy/Caddyfile` (base + per-app blocks) | `ansible.builtin.template`, blocks emitted by Jinja2 `{% if app_enabled %}` |
| L222-274 | portal `/srv/apps/portal/index.html` (conditional tiles) | `ansible.builtin.template` |
| L147 | family/search password → bcrypt | store the **hash** in `vault_search_password_hash`; render into Caddyfile (drop the runtime `caddy hash-password`) |
| L394-401 | validate-or-revert | template `validate: "caddy validate --adapter caddyfile --config %s"`; handler `reload caddy` |
| L152-155 | `basic_auth` vs legacy `basicauth` **probe** | **drop it** — Caddy version is pinned, so the directive is known |

**Handlers:** `reload caddy`. **Tags:** `proxy`.

### 6.11 `webui` ← `archive-webui-setup.sh`

| Source (line) | Operation | → Ansible |
|---|---|---|
| L83 | `git python3-recoll python3-waitress caddy` | `ansible.builtin.apt` |
| L91 | recoll-webui checkout at **pinned commit** `127f849…` | `ansible.builtin.git` (`version: <commit>`) |
| L94-113 | `archive-webui-run` launcher | `ansible.builtin.copy`/template |
| L117-150 | hardened `archive-webui.service` | `ansible.builtin.template` + `systemd_service` (enable) |
| L64-66 | `SVC_USER` = `stat` of archive root | `ansible.builtin.stat` + `set_fact` |
| L155-198 | Caddyfile ownership coordination (3-way detection) | **resolve with Caddy `import conf.d/*`** — each of proxy/webui drops a snippet into `/etc/caddy/conf.d/`, eliminating the who-owns-the-Caddyfile hack |

**Improvement:** the current three-way "who manages the Caddyfile" detection between `proxy` and
`webui` disappears once we adopt a Caddy `conf.d` import pattern — a cleaner design that Ansible makes
natural. **Handlers:** `reload caddy`, `restart archive-webui`. **Tags:** `webui`.

### 6.12 Explicitly **not** migrated

- **`make-ubuntu-usb.sh`** — imperative USB imaging on a *different* host (the Pi), with GPG
  verification, disk-safety picking, and dd write-back verification. Nothing declarative here. Stays
  bash, run by hand.
- **`archive-doctor.sh`, `archive-selftest.sh`, `archive-reset.sh`, `manage.sh`, `ci/`** — validation,
  orchestration, teardown, and tests. These *validate* the Ansible-built box (§8); they are not
  themselves Ansible.

---

## 7. `site.yml` shape

```yaml
- hosts: archive
  become: true
  vars_files: [inventory/group_vars/all/vault.yml]
  roles:
    - base
    - ingest            # renders /etc/archive-ingest.conf FIRST — the config bridge
    - search
    - serve
    - storage
    - restic
    - credentials       # always
    - { role: apps_common, tags: apps }
    - { role: app_immich,    tags: [apps, immich],    when: enable.immich }
    - { role: app_paperless, tags: [apps, paperless], when: enable.paperless }
    - { role: app_copyparty, tags: [apps, copyparty], when: enable.copyparty }
    - { role: app_czkawka,   tags: [apps, czkawka],   when: enable.czkawka }
    - { role: app_stirling,  tags: [apps, stirling],  when: enable.stirling }
    - { role: app_docmost,   tags: [apps, docmost],   when: enable.docmost }
    - { role: app_kopia,     tags: [apps, kopia],     when: enable.kopia }
    - { role: proxy, tags: proxy, when: enable.proxy }
    - { role: webui, tags: webui, when: enable.webui }
```

`enable.*` toggles in `group_vars` reproduce `manage.sh`'s optional-component choices; tags reproduce
its "reinstall just this one" behaviour (`--tags immich`). Ordering mirrors `manage.sh do_install`
(L62-99). `--check --diff` gives a dry-run preview — partly subsuming what `archive-doctor` reports.

---

## 8. Validation strategy — reuse what already exists

We do **not** write new validators; the bash system already ships two parity oracles and a
safety-invariant checker. They are implementation-agnostic (they inspect the box, not the installer),
so they judge an Ansible-built host unchanged.

1. **`archive-doctor.sh` — end-state oracle.** Read-only; exit 0 iff nothing FAILED. Run it as the
   final task of `site.yml` (`command: archive-doctor.sh`, `changed_when: false`) and/or as the CI
   acceptance gate. It checks mounts, read-only-remount trap, `nofail`, same-disk backup, `.INCOMPLETE`
   integrity, 0600 secrets, listening app ports, the Caddy front door and `.home` names, backup
   freshness markers, the search index, and the installed-command set. On a freshly-provisioned empty
   box, the *expected* warnings are the ones `archive-reset.sh` enumerates (empty archive, no backup
   yet) — the acceptance harness allowlists those.
2. **`archive-selftest.sh` — behaviour oracle.** Proves the *installed commands still enforce their
   guarantees*: block-layer write-block rejects a raw `dd`, the completeness gate leaves `.INCOMPLETE`
   on a short copy, bit-rot is detected, the scanned will is found by OCR. Needs loopback + sudo → its
   own CI job. Complements the doctor: doctor = "configured right", selftest = "the safety logic
   works".
3. **`ci/validate-compose.py` — safety-invariant checker.** Already renders each app's compose and
   asserts: every archive mount is `:ro`, must-not-touch apps don't mount the archive, Caddy-fronted
   apps bind loopback, `memorial` network is `external`. **Extend it** to also render the
   *Ansible-templated* compose (`ansible.builtin.template` output) and run the same assertions — so
   one check guards both provisioning paths.
4. **`ci/version-audit.sh`** — still applies: it verifies each pinned tag (now a `versions.*` var)
   still exists upstream via `skopeo list-tags`, never crying wolf on a rate-limited registry.
5. **New CI job — "provision a fresh box from the playbook."** On a bare `ubuntu-24.04` runner (or a
   container via Molecule), run `ansible-playbook --check` then a real converge, then
   `ansible-playbook` a **second** time asserting **zero changed tasks** (idempotence proof), then run
   `archive-doctor` (expect the empty-box exit profile) and the roundtrip drills. This is the guard
   that keeps the Ansible path from rotting — "it still builds a box" is proven on every push.

Idempotence is the headline Ansible win here: the current scripts hand-roll re-run safety with
`grep -q`/`command -v`/`sed` reuse; Ansible's second-run-is-green is a *tested* property, not a hope.

---

## 9. Phased execution plan (parity-gated)

Each phase is independently shippable and gated on the oracles above. No phase starts until the prior
phase's gate is green.

| Phase | Deliverable | Parity gate |
|---|---|---|
| **0. Scaffolding** | `ansible/` skeleton, `ansible.cfg`, inventory, `group_vars/all.yml` seeded from current `/etc/archive-ingest.conf` defaults, empty vault, Molecule/CI harness. No behaviour. | CI harness runs; `--syntax-check` passes |
| **1. Command extraction (bash repo)** | §2 refactor: promote embedded commands to `files/commands/`, setup scripts `install` them. | Existing shellcheck + roundtrips stay green; no functional change |
| **2. `base` role** | `provision.sh` parity. | Fresh container converges; idempotent 2nd run; base doctor checks pass |
| **3. Core roles** | `ingest`, `search`, `serve`, `storage`, `restic`, `credentials`. | `archive-doctor` (empty-box profile) + `archive-selftest` + backup/restic/search roundtrips green on an Ansible-built box |
| **4. App roles** | `apps_common` + the 7 app roles, one at a time. | `validate-compose` (incl. Ansible-rendered) + doctor app/port checks + `version-audit` |
| **5. Front door** | `proxy`, `webui` (with the Caddy `conf.d` refactor). | doctor front-door + `.home` name checks |
| **6. Cutover** | Ansible becomes the primary provisioning path; retire `provision.sh` plumbing and the setup scripts' provisioning halves (they keep only `install`-the-command, or are removed once the role owns it). Keep Layer B, imaging, and the doctor/selftest/CI. | Full `site.yml` on a fresh box → doctor exit 0 (post-ingest) end to end |

**Reconcilability during migration:** because Phase 1 makes the command bodies a single shared
source, a half-migrated box (some roles Ansible, some bash) is coherent — both paths install the
identical `/usr/local/bin` artifacts and read the identical `/etc/archive-ingest.conf`. The doctor
validates the result regardless of how each piece got there.

---

## 10. Risks, trade-offs, and non-goals

**Risks & mitigations**
- *Parallel drift* (the thing we're avoiding): mitigated by making Ansible **primary** (not a copy)
  and by the §2 single-source command bodies. Never maintain two implementations of the same logic.
- *Secret migration*: moving generated secrets into vault is a one-time, careful step. Do it per-role
  during that role's phase; verify `archive-credentials` still describes each correctly; keep files at
  0600 so `archive-doctor` stays happy.
- *Interactive steps that don't fit push-model automation*: `tailscale up` (needs auth),
  first-time physical disk selection, Docmost first-admin creation, Kopia per-PC onboarding. Keep
  these as documented manual/bash steps; Ansible manages everything around them.
- *Control-node question* (§11): push vs pull changes where Ansible itself lives.

**Explicit non-goals**
- Reimplementing any Layer B domain logic in Ansible (safe-mount, ingest-verify, verified backup,
  doctor, selftest).
- Ansible-ifying `make-ubuntu-usb.sh`.
- Exposing Ansible to the family. It is admin-only.
- Chasing "latest" at deploy time — we deliberately move to pinned, reviewed versions.

**What Ansible does *not* buy us**
- It doesn't make the box more capable day-to-day; the win is drift control, reproducible rebuilds,
  and hardened secrets. If those three stop mattering, the ROI drops — which is why the fresh-box CI
  job (keeping the path exercised) is mandatory, not optional.

---

## 11. Decisions needed before Phase 0

1. **Control model.** *Push* from the admin laptop over Tailscale SSH, or *pull* (`ansible-pull` +
   the vaulted repo on the box, self-contained like today)? Pull matches the current "the box manages
   itself" ethos and keeps working if the laptop is gone; push is simpler to reason about. Leaning
   **pull**, which also justifies keeping Ansible installed on the host (base role L216-227).
2. **Vault key management.** Single vault passphrase (simple) vs `sops`+`age` (nicer multi-key). Leaning
   **single passphrase** in the operator's password manager to start.
3. **Are Go / Rust / Chromium actually needed on the archive box,** or were they for the build/admin
   host? If vestigial, drop them from the `base` role (smaller attack surface). Needs your call.
4. **Retire vs bootstrap `provision.sh`.** At cutover, delete it, or keep a ~20-line bootstrap that
   installs Ansible + clones the repo and hands off to `ansible-pull`? Leaning **thin bootstrap**.
5. **Scope of Phase 1 first PR.** Recommend: the §2 command-extraction refactor **plus** the `base`
   role **plus** the fresh-container CI job — the smallest slice that proves the whole approach end to
   end (a real box provisioned and doctor-validated by Ansible) without touching the domain logic.

---

*This is a living plan. As roles land, update the phase table and the decisions section. The bash
system on `main` remains the source of truth for behaviour until a role reaches parity and passes its
gate.*
