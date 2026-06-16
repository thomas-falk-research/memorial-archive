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
- **A Tailscale-mounted ZFS share** (off-site/primary) — the backup target.
- The family browses from **iPhones/iPads** over Tailscale; there is no other computer.

Everything is config-driven, so it adapts to other disks, paths, networks, and devices.

---

## Scripts, in the order you run them

| # | Script | What it does | Run as |
|---|--------|--------------|--------|
| 0 | `make-ubuntu-usb.sh` | On *another* Linux box (e.g. a Raspberry Pi): build a verified, bootable Ubuntu installer USB. | `sudo` (it re-execs itself) |
| 1 | `provision.sh` | Base tooling: Docker + Compose, Ansible, Tailscale, Git + GitHub CLI, Rust, Go, Chromium, hardened SSH, correct UTF-8 locale, firewall + auto-updates. | regular user w/ sudo |
| 2 | `archive-ingest-setup.sh` | The ingestion core: read any disk/share **read-only** behind a write-block and make verified, checksummed master copies. Installs `safe-mount`, `ingest-verify`, `archive-verify`, and the guided `archive` menu. | regular user w/ sudo |
| 3 | `archive-search-setup.sh` | Make the archive keyword-searchable (a local, GUI-free "Everything" + full-text): `recoll`, `plocate`, Outlook-PST extraction. Installs `archive-index`, `archive-search`, `archive-find`. | regular user w/ sudo |
| 4 | `archive-serve-setup.sh` | Share the archive **read-only** over the tailnet so the family can browse it from the iPhone/iPad Files app. | regular user w/ sudo |
| 5 | `archive-storage-setup.sh` | Mount the external archive disk and the backup target safely (via `fstab`, `nofail`), and run **verified backups**. Installs `archive-storage`, `archive-backup`. | regular user w/ sudo |

> Run the setup scripts as your **normal user** (the one with sudo) — *not* with `sudo ./script`.
> They call `sudo` themselves where needed and must know your real home directory.

After `provision.sh`, authenticate the network and code tools once:
`sudo tailscale up`, then `gh auth login`.

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

After `archive-serve-setup.sh`, the archive is a **read-only** SMB share reachable **only over
Tailscale** (never the local network or internet). On each device (signed in to the same Tailscale
account):

1. **Files** app → **Browse**.
2. **⋯** (top-right) → **Connect to Server**.
3. Enter `smb://<this-machine's-tailscale-name>`.
4. Connect as a **Registered User** with the name/password you set during setup.

The family can view and copy, never change or delete.

### Optional: search from a phone (recoll web UI)

To let the family *keyword-search* (not just browse) from a phone, add the recoll web UI — it is
not packaged, so it's an opt-in extra. Bind it to the tailnet only:

```
sudo apt-get install -y python3-recoll git
git clone https://framagit.org/medoc92/recollwebui.git /opt/recoll-webui
# Run it bound to localhost or the tailscale IP, behind a systemd unit, using RECOLL_CONFDIR=/srv/archive/.recoll
```

Ask and this can be wired up as a hardened, tailnet-only service.

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
- The family share is **read-only** and **tailnet-only**.
- `fstab` changes use **`nofail`** and are validated with rollback, so a missing drive can never
  block boot.
- Backups are **additive** (never delete) and **verified** at the destination.
