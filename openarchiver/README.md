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
| `ocr` | **the deciding gate** — a token that exists *only inside a scanned image* is findable via attachment-content search | needs one UI import |
| `egress` | the app container itself cannot open an outbound connection, and still serves with the network cut | yes |
| `source` | sha256 before == after, and the file was not moved or consumed | yes, around the import |

Each gate is tested in **both** directions — a gate that cannot fail is not evidence. If a gate cannot
demonstrate its property it reports **UNPROVEN and exits non-zero** rather than defaulting to "probably
fine".

## `stage-mailbox.sh` — the only sanctioned way to get real mail in

Import directories are where irreplaceable files go to die. This one is mounted **read-only** into the
container, and even so, nothing but a verified copy is ever placed in it:

- the master is read-only, checksummed **before and after**, and the run fails if it changed by a byte
- the copy is verified byte-for-byte against the master — not "cp exited 0"
- free space is checked first, so a half-written copy is not the failure mode
- it refuses to overwrite, refuses to move, and deletes nothing
- provenance is appended to `import/PROVENANCE.tsv`, so a copy can always name its master

## Standing rules for this app

- **Never configure the Google Workspace / Microsoft 365 / IMAP connectors.** They are the only parts
  that reach the internet.
- **Back up `/srv/apps/openarchiver/.env` off the box.** `ENCRYPTION_KEY` and `STORAGE_ENCRYPTION_KEY`
  cannot be regenerated; without them the stored mail is unreadable.
- The index is **derived data** — rebuildable from the source mail. The mailbox masters are what matter.
- Remove the whole thing with `cd /srv/apps/openarchiver && sudo docker compose down -v`.
