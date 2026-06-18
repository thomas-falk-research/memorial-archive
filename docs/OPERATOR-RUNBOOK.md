# Operator Runbook — gathering a loved one's files

This is a step-by-step guide for the person doing the practical work of **getting all the files off a
family member's computers, drives, and USB sticks into one safe place**, and then **finding things**
in them (above all, the estate paperwork — the will). It is written for a **non-technical operator**:
you do not need to understand the commands, only to follow the steps.

The system is deliberately careful, in this order of priority:

1. **It never endangers the irreplaceable originals.** Every source drive is read **read-only** behind
   a write-block; the box only ever makes *copies*.
2. **It fails loudly, never silently.** A copy is not trusted until every file is checksum-verified;
   anything wrong is shown in plain English with the fix.
3. **It's simple.** You drive everything from **one menu**.

When in doubt, choose the safe, boring option, and **when you can't tell whether a file matters,
keep it** — you cannot know what will turn out to be precious.

---

## What you'll do (the big picture)

1. **Start fresh** — wipe the test data used while setting the box up, so nothing pollutes the real
   archive. *(One time, before any real files.)*
2. **Gather the files** — plug in each drive/USB **one at a time**, and copy the family's files into
   the archive, **labelled** so you always know which device each came from.
3. **Make it searchable** — rebuild the search index after the ingests.
4. **Find the will** — search across everything, including documents that were *scanned* to paper.
5. **Protect it** — verify the copies and run a backup.

Everything lands under `/srv/archive/incoming/<label>/<date-time>/` as a verified, checksummed copy
with a note of where it came from. The box serves it **read-only** to the family.

---

## What you need before you start

- The **archive box** (the mini-PC), already set up, on your network, and reachable. *(Imaging the
  box, Tailscale, and the iPhone/iPad share were done in earlier setup — this runbook assumes that.)*
- A way to **type commands on the box**: either its own keyboard/screen, or an SSH session from your
  laptop. The box's **login (sudo) password**.
- A **USB drive reader / dock** (SATA + NVMe) to connect the bare drives pulled from the dead PCs.
- The **drives and devices** themselves: the dead PCs' disks, the live PC, the USB sticks and
  external hard drives. Keep them in a pile and work through them **one at a time**.
- Something to **write new passwords down on, kept off the box** (a notebook or a password manager).

---

## How to read this runbook

Each step is tagged with **where** you do it:

- **[On the box]** — type it on the archive box (its terminal, or your SSH session).
- **[On the Windows PC]** — do it on the family's Windows computer.
- **[On an iPhone/iPad]** — do it on a family device.

Almost everything is **[On the box]**.

---

## The one command you need: `./manage.sh`

**[On the box]** Open a terminal, go to the toolkit folder, and run the menu:

```
cd ~/memorial-archive      # wherever the toolkit folder is
./manage.sh
```

Run it as your **normal user** — *not* with `sudo`. The menu can check health, (re)install, and do
the everyday tasks. The ones you'll use here are under **`6) Everyday tasks`**:

```
1) Ingest a drive / source   (guided menu)
2) Rebuild the search index
3) Search the archive        (find a document — e.g. the will)
4) Run a verified backup
5) Show storage status
6) Manage apps
7) Passwords & logins
```

If you ever get lost, choose **`1) Check health`** from the main menu — it inspects everything and
tells you, in plain English, what (if anything) is wrong and the exact fix. It changes nothing.

---

## Naming each device — the labelling convention

Every copy is filed under a **label** you choose, so months from now you still know which device a
file came from. Pick a short, memorable name **per device** and write it on a sticky note on the
drive as you go. Suggested style — *what it is + which one + a distinguishing detail*:

| Device | Example label |
|---|---|
| The live PC you're pulling from | `live-pc-dad-desktop` |
| First dead PC's main disk | `deadpc1-cdrive` |
| First dead PC's second disk | `deadpc1-nvme` |
| Second dead PC's disk | `deadpc2-hdd` |
| A blue 32 GB USB stick | `usb-blue-32g` |
| A Western Digital 2 TB external | `ext-wd-2tb` |

Use letters, numbers, and dashes. If you plug the same drive in twice, that's fine — each copy gets
its own date-and-time folder under the label, so nothing is overwritten.

---

## Step 1 — Start completely fresh (one time, before any real files)

While setting the box up you probably copied in some **test** files. Clear them now so they can't be
mistaken later for the real thing or clutter your searches.

> **Why now, and only now:** the box has **no real files or backups yet**, so this is the one safe
> moment to also reset *every* password — including the two that normally **can never be reset**
> (the off-site backup passphrase and the Windows-PC-backup password). Once real files are backed
> up, resetting those two would make those backups **unreadable forever** — so you do this **once**,
> here, and never again.

**[On the box]**

1. **Erase the test data.** From the toolkit folder:

   ```
   ./archive-reset.sh
   ```

   It shows exactly what it will delete, then asks you to type **`ERASE ALL DATA`** and then the
   **machine's name** to confirm. It keeps all the tools and settings — only data is erased.

2. **Reset the passwords** (a clean slate before the family relies on them). Run `archive-credentials`
   first — it lists every login and where it lives, **without ever showing a password**:

   ```
   archive-credentials
   ```

   Then reset the ones you use. For each, `archive-credentials` shows the exact step; the common ones:

   - **The box's own login:** `passwd` (only needed if it was ever shared).
   - **The family's shared search/files password** (if you set up the web front door):
     `RESET_SEARCH_PW=1 ./archive-proxy-setup.sh`
   - **The iPhone/iPad share password:** `sudo smbpasswd <the-share-username>`
   - **Photos (Immich) / Notes (Docmost):** you'll create the admin account fresh the first time you
     open each one. **Documents (Paperless)** keeps its admin — change it with the command
     `archive-credentials` prints if you want.
   - **Off-site encrypted backup (restic), *if you set it up*** — this is one of the un-resettable
     ones, so reset it now while it's empty:

     ```
     sudo rm -f /etc/archive-restic.pass        # forget the old passphrase
     sudo rm -rf /srv/backup/restic             # discard the (empty/test) encrypted repository
     ./archive-restic-setup.sh                  # creates a NEW passphrase — it prints it ONCE
     ```

     **Write the new passphrase down and keep it off the box.** Without it, the encrypted backup can
     never be opened.

   - **Windows-PC backup (Kopia), *if you set it up*** — the other un-resettable one:

     ```
     cd /srv/apps/kopia && sudo docker compose down
     sudo rm -f /srv/apps/kopia/.env            # forget the old repository password
     sudo rm -rf /srv/pc-backups/*              # discard the (empty/test) PC-backup repository
     cd ~/memorial-archive && ./archive-kopia-setup.sh   # new repository password
     ```

     **Record the new password off the box** (then re-add each PC with `archive-pc-backup add <name>`).

3. **Confirm it's clean and healthy:**

   ```
   ./archive-doctor.sh
   ```

   Expect **0 problems**. Notes like *"no index yet"*, *"no backup yet"*, or *"app data never backed
   up"* are **correct** on an empty box — they clear after your first real ingest and backup.

4. **(Optional, recommended) Put the "erase everything" tool out of reach.** Now that real files are
   about to go in, you never want to run the eraser by accident again. It is not an installed command
   — just a file in this folder — so you can simply remove it (and the test tool):

   ```
   rm archive-reset.sh archive-selftest.sh
   ```

   Everything else stays. *(If you ever run `manage.sh → Update`, it re-downloads these files; just
   remove them again, or skip Update once real data is in.)*

---

## Step 2 — Gather the files, one device at a time

> **Golden rule: one device at a time.** Plug in a single drive or USB, copy it, eject it, then move
> to the next. This keeps labels straight and avoids confusion.

For each device, you'll use **`./manage.sh` → `6) Everyday tasks` → `1) Ingest a drive / source`**.
That opens the **guided ingest menu**, which walks you through four choices:

```
1) See what drives are plugged in
2) Mount a drive safely (read-only)
3) Copy a mounted drive into the archive (verified)
4) Safely eject a drive
5) Show what is already in the archive
6) Check the archive for damage
```

The normal flow for one device is **2 → 3 → 4** (mount it, copy it, eject it).

### 2a. A dead Windows PC's drive (the usual case)

**[On the box]**

1. Pull the drive from the PC and connect it through your **USB drive reader**. *(The box is set so
   it will **not** auto-mount or write to it.)*
2. In the ingest menu, choose **`2) Mount a drive safely`**. It lists the drives it can see; pick the
   one you just plugged in. The box engages a **write-block** (so the drive physically cannot be
   changed) and mounts it **read-only**.
3. Choose **`3) Copy a mounted drive into the archive`**. It asks for a **label** — type the one you
   chose for this device (e.g. `deadpc1-cdrive`).
4. **If it's a Windows system disk**, the menu notices (it sees a `Users` folder next to `Windows`)
   and asks:

   > *Copy just the Users folder (recommended — skips the Windows system files)? [Y/n]*

   Answer **Y** (the default). This copies the **family's files** under `Users\` — documents,
   pictures, desktop, downloads — and skips Windows itself, the installed programs, and the giant
   system files. If you happen to know this drive *also* has important files **outside** `Users`
   (say a `D:` drive folder), answer **n** to copy the whole drive instead — *when unsure, keep
   more*.
5. The box copies the files, then **checks every one against a checksum**. You'll see **`VERIFY OK`**
   and **`Verified master copy: …`**. If anything couldn't be read, it says so loudly and leaves the
   copy marked `.INCOMPLETE` — it is **not** trusted; see *If something goes wrong* below.
6. Choose **`4) Safely eject a drive`**, then unplug it. Label the drive "DONE" and set it aside.

### 2b. The live Windows PC

The box gathers files from **drives**, not over the network, so there's no direct "pull from the live
PC" button. Two simple options — pick whichever is easier:

- **Easiest: treat it like the others.** Shut the PC down, pull its drive, and ingest it exactly as in
  **2a** (label it e.g. `live-pc-dad-desktop`). This captures everything in one pass.
- **Or copy its important folders to a USB stick first.** **[On the Windows PC]** copy the family's
  folders (Documents, Desktop, Pictures, Downloads, and anything else that matters) onto a USB stick
  or external drive. Then **[On the box]** ingest that USB as in **2c**.

### 2c. USB sticks and external hard drives

**[On the box]** Exactly like 2a, but these are almost always plain **data** drives (no operating
system), so the menu just copies the **whole** device — there's nothing to skip. Plug **one** in,
**Mount (2) → Copy (3)** with its label (e.g. `usb-blue-32g`, `ext-wd-2tb`) **→ Eject (4)**, and move
to the next.

### What to copy and what to skip

- **Copy:** anything that could be the family's — documents, photos, videos, email files, scans,
  spreadsheets, music, project folders. **When unsure, include it.**
- **Skip (handled for you on a Windows system disk):** Windows itself and programs —
  `Windows`, `Program Files`, `ProgramData`, `$Recycle.Bin`, `System Volume Information`, and the big
  `pagefile.sys` / `hiberfil.sys`. These are the operating system, not the family's files. (Choosing
  "just the Users folder" in step 2a.4 skips all of them.)

### When the menu asks about a "privileged copy"

For drives from a **Linux or Mac** computer, the menu may say the files are owned by other users and
offer a **privileged copy** — answer **Y**. (It still reads the drive read-only; it just reads as the
administrator so it can copy every file, and makes the copy readable for the family.) **Windows**
drives (NTFS/exFAT) don't need this and won't ask. *(If a copy ever stops with a "could not read some
files" error, re-run it and choose the privileged copy — the on-screen message tells you the exact
command.)*

### Old or failing drives

If a drive is old, clicking, or throwing errors, **don't keep retrying it** — that can finish it off.
The installer printed the steps to make a one-time **image** of it first (with `ddrescue`) and ingest
that image instead. Ask your technical helper, or see the notes in `archive-ingest-setup.sh`.

---

## Step 3 — Make everything searchable

After you've ingested some devices (you can do this after each one, or once at the end):

**[On the box]** `./manage.sh` → `6) Everyday tasks` → **`2) Rebuild the search index`**.

This reads **inside** every document — PDFs, Word/Excel/PowerPoint, email, text — so you can search
their **contents**, not just file names. It also reads **scanned** paperwork (a will photographed or
scanned to a PDF) using **OCR** (text recognition). **The first time is slower** because every scan
is read once; later runs are quick. Re-run it whenever you ingest more devices.

---

## Step 4 — Find the will (and everything else)

**[On the box]** `./manage.sh` → `6) Everyday tasks` → **`3) Search the archive`**. Type a few words;
it searches **inside** all the documents and lists the matches.

Words to try for the estate paperwork:

```
will          last will and testament       testament      estate
executor      beneficiary                   trust          probate
power of attorney        deed               insurance      401k
```

Tips:

- Several words means **all of them must appear**. To find an **exact phrase**, put it in quotes:
  `"power of attorney"`.
- A **scanned** will (a photo/scan, not typed) is found by its **contents** too, thanks to OCR — so
  searching `will` or `testament` will surface it even though it's "just a picture" of a document.
- To find something by its **file name** instead of its contents, that's `archive-find` on the box
  (e.g. `archive-find "*.pdf"`).

### The family can search and browse from their own devices

Once they're set up (earlier steps), the family doesn't need the box's terminal:

- **[On an iPhone/iPad]** **Search from a browser:** open `http://<box-name>.local:8080/` (or the
  friendly `http://search.<your-domain>/`), sign in with the shared family password, and type
  keywords.
- **[On an iPhone/iPad]** **Browse the files:** in the **Files** app → **Connect to Server** →
  `smb://<box-name>.local`, sign in as the registered user. They can **view and copy, never change or
  delete**.

---

## Step 5 — Protect what you've gathered

**[On the box]**

1. **Re-check the copies** any time (detects any disk rot): the ingest menu's
   **`6) Check the archive for damage`**, or run `archive-verify`.
2. **Back it up:** `./manage.sh` → `6) Everyday tasks` → **`4) Run a verified backup`**. This copies
   the archive to your backup drive/share and (if set up) takes an **encrypted off-site snapshot** —
   each verified at the destination. It never deletes from the backup.

Do a backup after your gathering is done, and on a regular schedule after that.

---

## Keeping it healthy

- **Full check, anytime:** `./archive-doctor.sh` (or `manage.sh → 1) Check health`). It's read-only
  and tells you the fix for anything wrong.
- **At-a-glance:** each time you log in to the box over SSH, a one-line summary shows free space and
  how fresh the last backup is.

---

## If something goes wrong

| What you see | What it means / what to do |
|---|---|
| A copy says **`.INCOMPLETE`** or **`rsync exit 23`** | Some files couldn't be read. **Don't trust that copy.** Re-run the copy; if it's a Linux/Mac drive, choose the **privileged copy**. If the drive is failing, image it first (see *Old or failing drives*). |
| **"Archive root … is on the ROOT filesystem"** | The archive disk isn't mounted. Run `archive-storage attach-archive` (or `./archive-doctor.sh` for the exact fix) before ingesting. |
| The drive won't appear in the menu | Make sure it's firmly connected through the reader; choose **`1) See what drives are plugged in`** to confirm the box sees it. |
| A search finds nothing you expect | Rebuild the index (**Everyday → 2**) — results are only as fresh as the last index. For a scanned document, make sure OCR is on (it is by default). |
| A friendly web address won't open | Use the box's plain network address instead: find it with `hostname -I` on the box and open `http://<that-number>/`. |
| Anything else feels off | Run **`./archive-doctor.sh`** first — it diagnoses the whole system and prints the fix. |

---

## Getting files back (the basics)

The whole point is that nothing is ever lost. If you need a file back:

- **From the backup mirror:** it's a plain, browsable copy under `/srv/backup/incoming/…` — copy the
  file straight back.
- **From an encrypted snapshot (restic), incl. an older version:** `archive-restic snapshots` to see
  the dated restore points, then `archive-restic restore latest --target /tmp/restore` (or an older
  snapshot's id). This recovers a file *as it was last week*, not just as it is now.
- **App data (Photos/Documents/Notes):** each backup folder under `/srv/backup/apps/` has a
  `RESTORE.txt` with the exact steps.

A fuller disaster-recovery guide (rebuilding the box from scratch) belongs alongside this document;
for now, `archive-doctor.sh` and the `RESTORE.txt` files cover the common cases.

---

## Quick reference (the commands behind the menu)

You normally never type these — the menu does — but for quick work on the box:

```
archive                         # the guided ingest menu (mount → copy → eject)
ingest-verify /mnt/ingest/<name>/Users <label>   # copy just a Windows disk's Users folder
archive-index                   # rebuild the search index (run after ingesting)
archive-search "will"           # search inside the documents
archive-find "*.pdf"            # search by file name
archive-verify                  # re-check every copy against its checksums
archive-backup                  # verified backup to /srv/backup
archive-credentials             # where every password lives + how to reset it
./archive-doctor.sh             # full read-only health check
```
