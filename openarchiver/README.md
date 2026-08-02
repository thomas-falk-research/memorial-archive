# `openarchiver/` — mail-native archive & search

Open Archiver indexes mail **as mail**: correspondent, date range, attachment presence — and it searches
the **text inside attachments**. That is the one question `recoll` (strings) and the RAG pilot (meaning)
cannot answer, and it is the natural shape of the hunt for John Sr.'s will, trust and death certificate.

Deployed by [`../archive-openarchiver-setup.sh`](../archive-openarchiver-setup.sh) · design and
reservations in [`../docs/OPENARCHIVER-ASSESSMENT.md`](../docs/OPENARCHIVER-ASSESSMENT.md).

---

## Order of operations

```bash
# 1. deploy (pinned, hardened, loopback-only)
bash archive-openarchiver-setup.sh

# 2. prove it is safe BEFORE any family mail
bash openarchiver/verify-openarchiver.sh all

# 2b. get the secrets off the box, and PROVE the copy arrived — before any large import
bash openarchiver/backup-env.sh
bash openarchiver/backup-env.sh verify ~/openarchiver-env-backup.txt --expect DIGEST

# 3. stage a COPY of a real mailbox (never the master)
bash openarchiver/stage-mailbox.sh "/srv/archive/incoming/.../Outlook MKH.pst"        # dry-run
bash openarchiver/stage-mailbox.sh "/srv/archive/incoming/.../Outlook MKH.pst" --go

# 4. import it in the UI, then prove your copy was left alone
bash openarchiver/verify-openarchiver.sh source
```

## `verify-openarchiver.sh` — four gates

| Gate | Proves | Automatic? |
|---|---|---|
| `harden` | reads the **running** config: telemetry off, loopback-only, archive not mounted, import read-only, deletion off, no cloud credentials, no upstream default secrets | yes |
| `ocr` | **the deciding gate** — a token that exists *only inside a scanned image* is findable via attachment-content search, **per format**: image-only PDF, single-page TIFF, a 3-page Group 4 fax TIFF with its token on page 3, GIF, and a 25-page PDF with its token on the last page | needs one UI import |
| `egress` | the app container itself cannot open an outbound connection, and still serves with the network cut | yes |
| `source` | sha256 before == after, and the file was not moved or consumed | yes, around the import |

Each gate is tested in **both** directions — a gate that cannot fail is not evidence. If a gate cannot
demonstrate its property it reports **UNPROVEN and exits non-zero** rather than defaulting to "probably
fine".

> **The `ocr` gate covers formats, not "OCR".** It once tested an image-only PDF only, and that
> result was being cited as "OCR works". The estate documents are `FaxImage.tif`, `image001.gif` and
> `SKM_*.pdf` — and a multi-page Group 4 fax TIFF is the least PDF-like image in ordinary use. Each
> format now carries its own token and is reported separately, and any format whose fixture is
> missing is named out loud, so a pass can never be read as covering more than it did.
> Regenerate the fixtures with `bash ci/make-fixtures.sh` (needs ImageMagick + tesseract).

## `preflight.sh` — one read-only pass over the whole box

Coming back to this after a break, the danger is not disagreement — it is two people confidently
remembering different boxes. `preflight.sh` measures, in one pass and changing nothing, every
property the ingestion plan depends on:

| | |
|---|---|
| **A repo** | is the checkout the reviewed code, clean, with all six tools present |
| **B release** | does the RUNNING image match compose, the repo's pin, and the current upstream release |
| **C stack** | all five containers, and the **backend on :4000** — the failure that once looked like a broken login |
| **D config** | hardening, plus the settings that decide whether a scan is found: `STORAGE_TYPE`, `ENABLE_DELETION`, `PDF_PARSE_TIMEOUT_MS` |
| **E secrets** | the `.env` digest, and whether you have asserted a verified off-box copy of **that exact file** |
| **F ingestion** | exactly which sources and how many messages exist, so "clear the experiments" has a known scope |
| **G network** | LAN vs link-local, Tailscale, the Caddy route, and whether `ORIGIN` matches how it will be reached |
| **H box** | disk and RAM against the ~68 GiB / ~4 GiB projections |

Three outcomes, deliberately: **OK**, **BLOCK**, and **UNKNOWN** — and UNKNOWN is *not* a pass. A
property it could not observe is a property nobody has observed. Exit codes follow: `1` blocking,
`3` unknowns only, `0` all clear.

It cannot see off-box storage, so it will not claim your `.env` backup exists. Assert it instead —
and the assertion is re-checked against the live file, so a backup taken **before** a re-key is
caught as STALE rather than passing:

```bash
bash openarchiver/preflight.sh --env-backup-verified DIGEST
```

Drilled by `ci/openarchiver-preflight-guard.sh` against a fully stubbed box — 18 cases, every
condition planted and required to BLOCK by name.

## `backup-env.sh` — the lockout gate, made falsifiable

`ENCRYPTION_KEY` and `STORAGE_ENCRYPTION_KEY` cannot be regenerated. Lose them and every message the
app has stored is permanently unreadable — the largest lockout risk in the stack, and it grows with
every mailbox imported. So the backup has to happen *before* the big import, and it has to be
**checked**, not assumed.

The usual failure is silent. `ssh HOST 'sudo cat /srv/apps/openarchiver/.env' > backup.txt` leaves a
**zero-byte file** when sudo cannot prompt for a password, and every check of the form "is the file
there?" passes on it. This tool is built around that trap:

| Mode | Does |
|---|---|
| `backup-env.sh` | fingerprints the live `.env` and prints the exact fetch + check commands, digest baked in |
| `backup-env.sh verify PATH --expect DIGEST` | checks the copy that actually arrived, from anywhere |
| `backup-env.sh verify PATH --manifest PATH` | same, off the box, using a saved digest-only manifest |

- **It never prints a secret value.** Only sha256 digests, which are one-way — so the output is safe
  to paste into a chat log or a ticket. An output guard scans the composed report for every value it
  read and *aborts* rather than printing one, and the drill proves that guard fires.
- **It refuses to imply success.** With no reference to compare against it reports **UNVERIFIED** and
  exits non-zero. Structure alone cannot tell a good backup from a perfectly valid `.env` belonging
  to a different install.
- **It names the failure.** Zero bytes · a captured `sudo: a terminal is required` · truncated in
  transit · rewritten to CRLF · an irreplaceable key missing, empty, or the wrong shape · a copy from
  a different install. Each gets a specific diagnosis, because "digests differ" tells you nothing
  about what to do next.
- Read-only. It writes nothing except a manifest at a path you name, and refuses to overwrite that.

Drilled in both directions by `ci/openarchiver-env-guard.sh` — 22 cases, each asserting the exit
status *and* that the output names the right reason. A case that merely accepts "non-zero" would
pass when the tool crashed for an unrelated reason, which is not evidence of anything.

## `stage-mailbox.sh` — the only sanctioned way to get real mail in

Import directories are where irreplaceable files go to die. This one is mounted **read-only** into the
container, and even so, nothing but a verified copy is ever placed in it:

- the master is read-only, checksummed **before and after**, and the run fails if it changed by a byte
- the copy is verified byte-for-byte against the master — not "cp exited 0"
- free space is checked first, so a half-written copy is not the failure mode
- it refuses to overwrite, refuses to move, and deletes nothing
- provenance is appended to `import/PROVENANCE.tsv`, so a copy can always name its master

## Two operational gotchas

**`ENABLE_DELETION=false` blocks deleting ingestion sources, not just mail.** That is the hardening
working as designed — nothing in this archive gets deleted by an app — but it also blocks ordinary
housekeeping like removing a test source. To do that deliberately:

```bash
sudo sed -i 's/^ENABLE_DELETION=false/ENABLE_DELETION=true/' /srv/apps/openarchiver/.env
cd /srv/apps/openarchiver && sudo docker compose up -d     # delete the source in the UI, then:
bash ~/memorial-archive/archive-openarchiver-setup.sh --yes   # puts it back to false
```

**Creating an ingestion source starts the import immediately.** There is no separate "run" step, so
stage the file and set the checkboxes *before* submitting. In the Advanced Options:

- **Preserve Original File — CHECKED.** Unchecked, the app deletes or moves its source. The
  read-only `import/` mount turns that into a loud failure rather than a lost copy, but do not rely
  on it.
- **Merge into existing ingestion** — leave unchecked unless you specifically want generations of one
  mailbox folded together.

## Standing rules for this app

- **Never configure the Google Workspace / Microsoft 365 / IMAP connectors.** They are the only parts
  that reach the internet.
- **Back up `/srv/apps/openarchiver/.env` off the box.** `ENCRYPTION_KEY` and `STORAGE_ENCRYPTION_KEY`
  cannot be regenerated; without them the stored mail is unreadable.
- The index is **derived data** — rebuildable from the source mail. The mailbox masters are what matter.
- Remove the whole thing with `cd /srv/apps/openarchiver && sudo docker compose down -v`.
