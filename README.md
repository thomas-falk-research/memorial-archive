# memorial-archive

Tooling to turn a dedicated Ubuntu mini-PC into a **digital-archive server**: a safe place to
gather everything off a person's drives, computers, phones, and shares; copy it in with
verified, checksummed integrity; make every file keyword-searchable; and let the family browse
it from their iPhones and iPads — with on-site and (optionally) off-site backups.

It was built to help a non-technical family centralize and preserve a loved one's files after
an unexpected loss. The scripts are deliberately conservative: they read source media
**read-only**, never trust a copy until its checksums verify, and serve the result **read-only**.

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
| 3 | `archive-search-setup.sh` | Make the archive keyword-searchable (a local, GUI-free "Everything" + full-text): `recoll`, `plocate`, Outlook-PST extraction. Installs `archive-index`, `archive-search`, `archive-find`. | regular user w/ sudo |
| 4 | `archive-serve-setup.sh` | Share the archive **read-only** on the local network so the family can browse it from the iPhone/iPad Files app (SMB). | regular user w/ sudo |
| 5 | `archive-storage-setup.sh` | Mount the external archive disk and the backup target safely (via `fstab`, `nofail`), and run **verified backups**. Installs `archive-storage`, `archive-backup`. | regular user w/ sudo |
| 6 | `archive-webui-setup.sh` | Let the family **keyword-search** the archive from a phone browser — the recoll web UI behind a password-protected Caddy proxy on the local network. | regular user w/ sudo |

> Run the setup scripts as your **normal user** (the one with sudo) — *not* with `sudo ./script`.
> They call `sudo` themselves where needed and must know your real home directory.

After `provision.sh`, authenticate the tools once: `sudo tailscale up` (for *your* remote admin
and the off-site backup), then `gh auth login`.

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
archive-verify                   # re-check every copy against its checksums (detect bit-rot)
```

Each verified copy lands in `/srv/archive/incoming/<label>/<timestamp>/` with a `SHA256SUMS`
manifest and a `PROVENANCE.txt`. A copy stays marked `.INCOMPLETE` until it fully passes, so a
partial copy is never mistaken for a good one.

**Read-only is enforced three ways:** desktop auto-mount is disabled, a udev rule stops USB media
from auto-mounting, and `safe-mount` engages a verified block-layer write-block before mounting.
Old/failing drives should be imaged first with `ddrescue` (see the notes printed by the installer).

---

## Day-to-day: searching

After an ingest, refresh the indexes, then search:

```
archive-index                    # extract any PST/OST, then (re)build the full-text + filename indexes
archive-search "life insurance"  # search INSIDE files (PDF, Office, RTF, text, email, ...) with snippets
archive-find  "*.pst"            # instant search by file NAME (substring or glob)
```

The indexes live **on the archive volume** (`/srv/archive/.recoll`, `/srv/archive/.plocate.db`),
so they grow with the archive, never the OS disk.

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
| `MAX_ARCHIVE_GIB` | `1800` | Soft cap; `archive-storage` warns as you approach it. |

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
