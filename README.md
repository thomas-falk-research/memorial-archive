# memorial-archive

Tooling to turn a dedicated Ubuntu mini-PC into a **digital-archive server**: a safe place to
gather everything off a person's drives, computers, phones, and shares; copy it in with
verified, checksummed integrity; make every file keyword-searchable; and let the family browse
it from their iPhones and iPads — with on-site and (optionally) off-site backups.

It was built to help a non-technical family centralize and preserve a loved one's files after
an unexpected loss. The scripts are deliberately conservative: they read source media
**read-only**, never trust a copy until its checksums verify, and serve the result **read-only**.

---

## Start here: one menu — `./manage.sh`

You don't have to remember any of the script names below. From this folder, run:

```
./manage.sh          # (or:  bash manage.sh )
```

It's a guided menu for the whole system:

- **Check health** — verify everything (runs `archive-doctor`).
- **Install / set up** — runs the steps below in order, asking before each one.
- **Update** — `git pull` the latest, then safely refresh what's installed. Passwords, settings, and
  data are preserved; app versions advance to the latest.
- **Reinstall / repair** — re-run setup to fix a broken command/service, without changing versions.
- **Uninstall** — removes the tools only; it **never** touches your archive (`/srv/archive`) or backups.
- **Everyday tasks** — ingest a drive, rebuild the search index, run a verified backup, show storage.

Run it as your normal user (the one with sudo) — *not* with `sudo`. Everything below still works on
its own for advanced use; the menu just drives it for you.

---

## The machine and storage

- A dedicated mini-PC running **Ubuntu 26.04 LTS** (desktop).
- **1 TB internal NVMe** — the OS and working disk.
- **2 TB external NVMe SSD** — the archive (the verified master copies live here).
- **A Tailscale-mounted ZFS share** (off-site) — the backup target.
- The family browses/searches from **iPhones/iPads on the home Wi-Fi**; there is no other computer.
- **Tailscale** is for *your* remote administration (SSH in to run and support it) and to mount the
  off-site backup share — it is **not** required for the family's day-to-day access.

Everything is config-driven, so it adapts to other disks, paths, networks, and devices.

---

## Scripts, in the order you run them

| # | Script | What it does | Run as |
|---|--------|--------------|--------|
| 0 | `make-ubuntu-usb.sh` | On *another* Linux box (e.g. a Raspberry Pi): build a verified, bootable Ubuntu installer USB. | `sudo` (it re-execs itself) |
| 1 | `provision.sh` | Base tooling: Docker + Compose, Ansible, Tailscale, Git + GitHub CLI, Rust, Go, Chromium, hardened SSH, correct UTF-8 locale, firewall + auto-updates. | regular user w/ sudo |
| 2 | `archive-ingest-setup.sh` | The ingestion core: read any disk/share **read-only** behind a write-block and make verified, checksummed master copies. Installs `safe-mount`, `ingest-verify`, `archive-verify`, and the guided `archive` menu. | regular user w/ sudo |
| 3 | `archive-search-setup.sh` | Make the archive keyword-searchable (a local, GUI-free "Everything" + full-text): `recoll` (indexes inside PDF — incl. **scanned**, via OCR — Office, email, archives), `plocate`, Outlook-PST extraction. Installs `archive-index`, `archive-search`, `archive-find`. | regular user w/ sudo |
| 4 | `archive-serve-setup.sh` | Share the archive **read-only** on the local network so the family can browse it from the iPhone/iPad Files app (SMB). | regular user w/ sudo |
| 5 | `archive-storage-setup.sh` | Mount the external archive disk and the backup target safely (via `fstab`, `nofail`), and run **verified backups**. Installs `archive-storage`, `archive-backup`. | regular user w/ sudo |
| 6 | `archive-apps-setup.sh` | *(optional, Docker)* **Manage every app from one command** (`archive-apps`): status · update/pull · logs · restart, across Immich/Paperless/copyparty/etc. Each app keeps its **own** Compose project (data volumes are never renamed); also creates a shared `memorial` network. | regular user w/ sudo |
| 7 | `archive-webui-setup.sh` | Let the family **keyword-search** the archive from a phone browser — the recoll web UI behind a password-protected Caddy proxy on the local network. | regular user w/ sudo |
| 8 | `archive-immich-setup.sh` | *(optional, Docker)* Self-hosted **photos & videos** (Immich) with native iPhone/iPad apps; indexes the archive's photos **read-only, in place** (no copy). Serves on `:2283`. | regular user w/ sudo |
| 9 | `archive-paperless-setup.sh` | *(optional, Docker)* **Document manager** (Paperless-ngx): OCRs, tags, and searches documents you drop into its `consume/` folder. Serves on `:8000`. | regular user w/ sudo |
| 10 | `archive-copyparty-setup.sh` | *(optional, Docker)* **Read-only web file browser** (copyparty): browse and download *any* file in the archive from a phone/computer browser — no app, no SMB setup. Archive bind-mounted **read-only**; listens on loopback only (publish it via the front door). | regular user w/ sudo |
| 11 | `archive-proxy-setup.sh` | *(optional)* One **front door**: Caddy on `:80` serves a **portal page** and routes friendly names — `photos.<domain>` → Immich, `docs.<domain>` → Paperless, `search.<domain>` → recoll, `files.<domain>` → copyparty — so the family uses memorable URLs with **no ports**. Pair with AdGuard/router DNS rewrites. | regular user w/ sudo |

> Run the setup scripts as your **normal user** (the one with sudo) — *not* with `sudo ./script`.
> They call `sudo` themselves where needed and must know your real home directory.
>
> **Updating later?** These scripts install commands into `/usr/local/bin` (`archive`,
> `archive-backup`, `archive-storage`, …). A `git pull` refreshes the files in this folder but **not**
> those already-installed commands — so after you update the repo, **re-run the matching `*-setup.sh`**
> to pick up the fix. Re-running is safe; every script is idempotent.
>
> Scripts 8–10 are the optional family-facing apps (Docker Compose stacks). Their data lives on the OS
> disk under `/srv/apps` (off the 2 TB archive budget); Immich and copyparty reference the archive
> read-only, so the masters are never modified. Each is pinned to a specific upstream release and
> re-runnable. Once you have more than one, `archive-apps-setup.sh` (script 6) gives you a single
> command — `archive-apps` — to see, update, log, and restart them all (each keeps its own Compose
> project, so data is never moved).

After `provision.sh`, authenticate the tools once: `sudo tailscale up` (for *your* remote admin
and the off-site backup), then `gh auth login`.

---

## Check everything: `archive-doctor`

Not sure it's all healthy — or you just pulled an update and want to confirm? Run the **read-only**
health check from this folder:

```
./archive-doctor.sh
```

It inspects storage and mounts — including the things that **break silently**: an archive that's
**not writable** by the ingest user or has **remounted read-only** after disk errors, a backup that
landed on the **same disk** as the archive, a full OS disk, missing `fstab` `nofail`, loose
credential/permission bits, and (best-effort) disk **SMART** health. It also checks the archive's
`.INCOMPLETE`/checksum integrity, the on-site/off-site backup (and how fresh it is), the search index,
the family apps (Immich/Paperless) and the Caddy front door, the friendly `.home` names, and the
installed commands (flagging any that are out of date versus the repo — the *stale-install trap*) —
and prints a plain-English ✓ / ! / ✗ for each, with a concrete **fix** for anything that isn't right.
It changes nothing, so it is always safe to run. (Its exit code is non-zero if any check failed, so a
scheduled job can use it too.)

**You don't have to run it every time.** Once storage is set up, a one-line health summary — archive
free space, how close you are to the soft cap, and how fresh the last verified backup is — is shown
automatically at each SSH login (a fast, read-only `/etc/update-motd.d` banner; it uses `df` only, so
it never slows a login). It's a heads-up; the full picture is always `./archive-doctor.sh`.

---

## Day-to-day: gathering files

For everyday work, just run the guided menu:

```
archive
```

It walks an operator through: see what's plugged in → mount it **read-only** → copy it into the
archive **with verification** → eject. The expert commands behind the menu:

```
safe-mount                       # pick a drive; mount it read-only behind a block-layer write-block
ingest-verify /mnt/ingest/NAME LABEL   # verified copy into the archive (space + completeness + SHA-256)
ingest-verify --privileged /mnt/ingest/NAME LABEL   # for Linux/Mac disks (see below)
archive-verify                   # re-check every copy against its checksums (detect bit-rot)
```

Each verified copy lands in `/srv/archive/incoming/<label>/<timestamp>/`: the source files
themselves under `data/`, alongside a `SHA256SUMS` manifest and a `PROVENANCE.txt`. A copy stays
marked `.INCOMPLETE` until **every** source file has been copied and verified, so a partial copy is
never mistaken for a good one. Before each copy `ingest-verify` checks there's enough room, and warns
(without blocking) if the copy would take the archive near or over its `MAX_ARCHIVE_GIB` soft cap.

**Linux or Mac source disks** (ext4/btrfs/XFS, HFS+/APFS) often have files owned by other users or
root that your normal account can't read — a plain copy would be (correctly) refused as incomplete.
For those, use a **privileged copy**: `ingest-verify --privileged` reads the source as root (the drive
stays mounted read-only, so it's never modified) and writes the copy **owned by you and readable**, so
the family's read-only serving can see every file. The guided `archive` menu detects these
filesystems and offers it automatically; Windows drives (NTFS/exFAT) don't need it.

**Read-only is enforced three ways:** desktop auto-mount is disabled, a udev rule stops USB media
from auto-mounting, and `safe-mount` engages a verified block-layer write-block before mounting.
Old/failing drives should be imaged first with `ddrescue` (see the notes printed by the installer).

---

## Day-to-day: searching

After an ingest, refresh the indexes, then search:

```
archive-index                    # (re)build the full-text + filename indexes (extracts PST/OST, OCRs scans)
archive-search "life insurance"  # search INSIDE files with snippets
archive-find  "*.pst"            # instant search by file NAME (substring or glob)
```

`archive-search` looks **inside every common format** — PDF (including **scanned** PDFs, via OCR),
Word/Excel/PowerPoint (modern and legacy) and OpenDocument, RTF/HTML/plain text, email
(PST/OST/mbox/EML/Outlook `.msg`), and inside archives (zip/7z/tar/rar). Anything with no extractable
text (an obscure binary, a photo) is still found by **name** with `archive-find`. So *every* file is
findable, and the contents of normal documents — and of scanned paperwork — are full-text searchable.

OCR of scanned PDFs is on by default (tesseract). It makes the **first** index slower (each scan is
read once, then cached). Tune it in `/etc/archive-ingest.conf`: `OCR_ENABLE=false` to skip it, or
`OCR_LANG=eng+deu` for extra languages. The indexes live **on the archive volume**
(`/srv/archive/.recoll`, `/srv/archive/.plocate.db`), so they grow with the archive, never the OS disk.

---

## The family: browsing from an iPhone/iPad

After `archive-serve-setup.sh`, the archive is a **read-only**, password-protected SMB share on
the **home network** (not the public internet). On each device, on the same Wi-Fi:

1. **Files** app → **Browse**.
2. **⋯** (top-right) → **Connect to Server**.
3. Enter `smb://<this-machine>.local` (or the machine's LAN IP).
4. Connect as a **Registered User** with the name/password you set during setup.

The family can view and copy, never change or delete.

## The family: searching from a phone

After `archive-webui-setup.sh`, the family can keyword-search the whole archive — file *contents*
(PDF/Office/RTF/email/…) and *names* — from a phone browser. On the home Wi-Fi, open Safari/Chrome:

```
http://<this-machine>.local:8080/        (or  http://<LAN-IP>:8080/)
```

Sign in with the web login (default name `family`, password set during setup), type keywords, and
tap a result to open or download it. It is **read-only** and **password-protected**: the recoll web
UI runs only on loopback and Caddy publishes it on the LAN with the password. Re-run `archive-index`
after new ingests so results stay current.

## The family: browsing files from a phone

After `archive-copyparty-setup.sh` (+ the front door), the family can **browse and download any file**
in the archive from a plain browser — folder by folder, with thumbnails — without the iOS Files-app
"Connect to Server" step. On the home Wi-Fi, open Safari/Chrome:

```
http://files.<domain>/        (e.g. http://files.home/ — needs the AdGuard rewrite the proxy prints)
```

Sign in with the same `family` login as search. It is **strictly read-only**, four ways over: the
archive is mounted into the container **read-only**, copyparty grants only read (no upload/delete),
it listens on **loopback** only, and Caddy fronts it with the **password**. The family can view and
copy; they can never change or delete a master.

---

## Managing the apps: `archive-apps`

As the number of Docker apps grows (photos, documents, file browser, …), `archive-apps-setup.sh`
installs one command so you don't have to `cd` into each app's folder:

```
archive-apps status            # what's running, across every app
archive-apps update            # pull newer images + recreate — updates them all
archive-apps logs <app>        # follow one app's logs (e.g. archive-apps logs immich)
archive-apps restart           # restart everything
archive-apps up | down         # start / stop everything
```

Crucially, **each app keeps its own Compose project** under `/srv/apps/<app>` — `archive-apps` just
runs `docker compose` across all of them. It deliberately does **not** merge them into one project,
because that would rename their data volumes (e.g. Paperless's documents and database) and orphan
them. It also creates a shared `memorial` Docker network that newer apps join, so a future
containerised front door can reach them by name. (`manage.sh → Everyday tasks → Manage apps` runs
the same thing.)

---

## Backups

```
archive-storage                  # show the layout + health (mounts, free space, soft cap, last backup)
archive-storage attach-archive   # mount the 2 TB external as /srv/archive (guided, by UUID, nofail)
archive-storage attach-backup    # mount an external drive OR a Tailscale NFS/SMB share at /srv/backup
archive-backup                   # verified, additive backup to /srv/backup; re-checks every checksum
```

`archive-backup` never deletes from the backup, refuses to "back up" onto the same disk as the
archive, and is only declared good once every destination checksum verifies.

### Immich and Paperless data is backed up too

Those apps keep their own data **outside** the archive — Paperless stores its OCR'd documents, tags
and metadata; Immich stores albums, people/faces and any photos uploaded from a phone — so a backup
of `/srv/archive` alone would not bring them back. `archive-backup` therefore **also** backs up each
installed app, into `/srv/backup/apps/`:

- **Paperless** → its own `document_exporter` (documents + OCR text + tags + `manifest.json`).
- **Immich** → a full database dump (albums/people/tags) plus any uploaded originals (regenerable
  thumbnails and transcodes are skipped).

Each lands beside a `RESTORE.txt` with the exact restore commands. This step is **best-effort**: if
an app is stopped, `archive-backup` warns but the archive backup itself stays verified. Disable it
with `BACKUP_APPS=false` in `/etc/archive-ingest.conf`; `archive-doctor` reports when the apps were
last backed up.

---

## Settings

All commands read `/etc/archive-ingest.conf` (edit and re-run — no reinstall):

| Key | Default | Meaning |
|-----|---------|---------|
| `ARCHIVE_ROOT` | `/srv/archive` | Where verified master copies are written. |
| `INGEST_MNT` | `/mnt/ingest` | Where source media is mounted read-only. |
| `REQUIRE_MOUNTED_DEST` | `true` | Refuse to ingest unless the archive is a separate mounted volume. |
| `MIN_FREE_GIB` | `10` | Keep at least this many GiB free after a copy. |
| `BACKUP_ROOT` | `/srv/backup` | Where backups are written. |
| `REQUIRE_SEPARATE_BACKUP` | `true` | Refuse to back up onto the same filesystem as the archive. |
| `MAX_ARCHIVE_GIB` | `1800` | Soft cap; you're warned as you approach it — at ingest, at each SSH login, and in `archive-storage`/`archive-doctor`. |
| `OCR_ENABLE` | `true` | OCR scanned PDFs during `archive-index` so their text is searchable (needs `tesseract`). Set `false` to skip. |
| `OCR_LANG` | `eng` | tesseract OCR language(s), e.g. `eng+deu`. Install the matching `tesseract-ocr-<lang>` package. |

Per-user overrides may go in `${XDG_CONFIG_HOME:-~/.config}/archive-ingest.conf`.

---

## Safety summary

- Source media is read **read-only**, behind a verified block-layer write-block; the OS disk is
  always refused.
- Copies are **checksum-verified** (SHA-256) and carry provenance; bit-rot is detectable later.
- The family's access (the SMB share and the search web UI) is **read-only** and
  **password-protected**, on the local network — not the public internet. Tailscale is only for
  your remote administration and the off-site backup mount.
- `fstab` changes use **`nofail`** and are validated with rollback, so a missing drive can never
  block boot.
- Backups are **additive** (never delete) and **verified** at the destination.

---

## Before real data: prove the pipeline — `archive-selftest.sh`

Want proof the whole ingestion chain works on the real drive formats *before* you trust it with
irreplaceable data (and again after any update)? Run the end-to-end self-test:

```
./archive-selftest.sh
```

It builds small **scratch** loopback "drives" in a temp dir — it never touches `/srv/archive` or your
backup — formats each with a different filesystem (ext4, NTFS, exFAT, FAT32, and HFS+ when `hfsprogs`
is installed), seeds them with deliberately awkward files (spaces/Unicode/newlines in names, a file
literally called `SHA256SUMS`, an empty file, nested folders), and runs each through the **real**
`safe-mount` → `ingest-verify` → `archive-verify` pipeline — asserting the *safety* properties, not
just the happy path:

- the write-block actually **rejects a write**, and the mount is read-only;
- the copy verifies, with the correct `data/` layout, manifest and provenance;
- an **incomplete** copy is refused and left `.INCOMPLETE` (the hard completeness gate);
- ingesting into a **non-mounted** archive is refused;
- `archive-verify` **fails a single tampered byte** (bit-rot detection);
- the failing-drive workflow (`ddrescue` an image, then ingest the image) works.

It cleans up after itself (unmounts, detaches the loopbacks, removes the scratch dir). Like
`archive-reset.sh`, it is intentionally **not** installed and **not** in the menu; run it from this
folder as your normal user (it needs `sudo` for loopback devices). **APFS and BitLocker can't be
created on Linux**, so they aren't covered automatically — test those with real media (an APFS drive
from a Mac; a BitLocker volume — `safe-mount` now detects both and prints the unlock/ingest steps).

---

## Starting fresh: erase test data before real data

While setting the system up you'll likely ingest test files and drop sample documents/photos into
Paperless and Immich. Before the **real** data goes in, wipe all of that — otherwise it pollutes
search results, and a stray test document could be mistaken by the family for the real thing.

Test data hides in several places: the archive copies **and** the search indexes; the **off-site
backup** (which is additive, so deleting from the archive does *not* remove it from the backup); and
each app's **own database** (Immich albums/people, Paperless documents). `archive-reset.sh` clears
all of them in one deliberate, guarded step:

```
./archive-reset.sh
```

It is intentionally **not** installed as a command and **not** in the `manage.sh` menu, so it can't
be run by accident. It must be run at a real terminal; it **shows exactly what it will delete**, then
requires **two different** typed confirmations (`ERASE ALL DATA`, then the machine's hostname). It
**keeps** all tooling and configuration — only data is erased — and re-initialises Immich and
Paperless empty (Paperless keeps its admin login; in Immich you re-create the admin, re-add the
read-only `/mnt/archive` library, and re-add family users). There is no undo and no `--yes` mode.

Afterwards, run `./archive-doctor.sh` to confirm an empty-but-healthy box (warnings about "no index
yet" / "no backup yet" are expected on an empty archive and clear after your first real ingest).

---

## Notes & troubleshooting (lessons from a real install)

- **First thing when anything seems off:** run `./archive-doctor.sh`. It checks the whole system
  read-only and tells you, in plain English, what's wrong and the exact command to fix it.
- **Downloaded the repo as a ZIP?** ZIPs don't keep the executable bit, so first:
  `chmod +x *.sh`. (A `git clone` preserves it.)
- **Run long installs inside `tmux`** (`sudo apt install -y tmux; tmux new -s setup`) so a dropped
  SSH session can't interrupt a half-finished install. Reconnect with `tmux attach -t setup`.
- **Every setup script is idempotent** — safe to re-run if it was interrupted, or to reinstall the
  latest version of its commands after a `git pull`. If an installed command (`archive-backup`,
  `archive-storage`, …) ever behaves differently from what these docs describe, an out-of-date copy is
  the likeliest cause — re-run its `*-setup.sh` first.
- **Ingesting a native Linux disk (ext4/btrfs/XFS) or a Mac disk (HFS+/APFS)?** Such a source has
  files owned by root or other users (even an empty Linux disk has a root-only `lost+found`) that the
  unprivileged ingest user can't read, so a plain `ingest-verify` (correctly, with a clear `rsync exit
  23` message) refuses the copy as incomplete rather than silently skipping files. Use a **privileged
  copy**: `ingest-verify --privileged <src> <label>` (the guided `archive` menu offers it automatically
  for these filesystems). It reads the source as root — the drive stays mounted read-only, so it's
  never modified — and writes the copy owned by you and readable. Windows media (NTFS/exFAT) is
  unaffected and doesn't need it.
- **Tailscale on a fresh box won't finish login from a remote SSH session.** Do `sudo tailscale up`
  at the machine's own keyboard/console (complete the browser login while the command is still
  running), or pass a pre-generated `--authkey`. Once it's up you can SSH in over the tailnet.
- **NFS backup target shows `clnt_create: RPC: Program not registered`?** That's `showmount`
  (an NFSv3 tool) failing against an **NFSv4** server — harmless. Skip `showmount` and mount
  directly: `sudo mount -t nfs -o vers=4.1,nofail <server>:/path /srv/backup`.
- **SMB/CIFS backup target** (e.g. an Unraid share that needs a username/password): `archive-backup`
  detects it and copies contents + timestamps (SMB can't store Unix permissions); integrity is
  still proven by the SHA-256 manifest check. Mount it with `archive-storage attach-backup` → SMB.
- **A friendly name (`archive.home`, `photos.home`, `docs.home`, `search.home`) won't open?** The
  device must get its DNS from **AdGuard Home**, where those name→IP rewrites live (family
  iPhones/iPads do if AdGuard is the network's resolver). The machine's **LAN IP always works**
  regardless — find it with `hostname -I` and open `http://<that-ip>/`.
- **Apple APFS drives:** `archive-ingest-setup.sh` builds `apfs-fuse` from source (best-effort). If
  that build failed (it's non-fatal), APFS read support is missing — check the installer log at
  `~/archive-ingest-setup.*.log`, install any missing build deps, and re-run the script.
- **`sudo` password prompts appear in the terminal and show nothing as you type** — that's normal,
  not a hang.
