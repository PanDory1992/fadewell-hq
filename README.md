# FADEWELL HQ

Private operating system and canonical DEN Ledger for the Vinted business. It
is intentionally read-only against Vinted, stores external Vinted photo URLs
only, and turns disagreements into review items rather than changing Vinted.
Google Sheet is read-only legacy history and the excluded REC stream.

## Run locally

```powershell
python fadewell_hq\app.py sync
python fadewell_hq\app.py serve
```

Open `http://127.0.0.1:8765`.

## Supabase parallel sync

Copy `.env.example` to `.env`, set the server-only key there, then run:

```powershell
$env:SUPABASE_SERVICE_ROLE_KEY='...'; python fadewell_hq\supabase_sync.py
```

The secret key never belongs in browser code or Git. It permits the local
sync job to write the private operational copy protected by RLS.

## Data policy

- `data/hq.sqlite` is a local operational cache and is ignored by Git.
- Canonical Ledger actions write only to HQ; Google Sheet is never a writeback target.
- Vinted images are referenced by URL and are never downloaded or stored.
- A disappearing listing becomes `MISSING`, then requires review as sold, relist,
  hidden/removed, or unknown.
- The planned audit migration will make Ledger history append-only; until it is
  reviewed and applied, treat the export verifier as backup integrity evidence,
  not proof that remote event rows cannot be changed.

## Backup and export

Run `python fadewell_hq\backup_canonical.py` to create an atomic, checksummed
JSON bundle under `fadewell_hq\backups\`. It contains canonical items, the
full Ledger event history, and intake-event state. Verify any copied bundle
offline with `python fadewell_hq\canonical_export.py --verify <bundle-path>`.
Backups are private local artifacts and do not change Google Sheet or Vinted.
