# FADEWELL HQ — AI Operating Guide

This is the practical entrypoint for any AI working on FADEWELL HQ. It describes the **current operating model**, safe ways to read and change HQ, and the required verification standard.

## 1. What HQ is

FADEWELL HQ is the operating system for the denim business:

- **HQ / Supabase is canonical** for DEN items, bookkeeping, purchases, listings, sales, Vinted observations, DNA, pricing, finance, sourcing and operational queues.
- The live application is [hq.fadewell.eu](https://hq.fadewell.eu).
- Google Sheets are no longer a source or write target for DEN operations. They may be used only for REC items or historical reference when explicitly relevant.
- Vinted is an observed external marketplace. HQ may collect its public listing state, but must never silently modify a Vinted listing.

If an older document says that Google Sheets are canonical or that HQ is only a prototype, it is historical context. The newest direct user decision and the current `docs/core/CURRENT_STATE.md` win.

## 2. Non-negotiable operating rules

1. **Read before changing.** Re-read the exact file, record, migration, workflow or UI component immediately before editing it.
2. **Do not invent business facts.** A missing date, price, identity, sale or match remains unknown until evidence or an explicit human decision exists.
3. **Do not infer a sale from a missing listing.** Delisting, collector failure and a private/hidden listing are all possible.
4. **DEN is the immutable business key.** A title may change; a DEN must not be reused or silently reassigned.
5. **Preserve provenance.** Every meaningful automation result needs a source, timestamp and evidence/reference where available.
6. **Human decisions are explicit events.** A correction, sale resolution, purchase allocation or link should be auditable rather than overwriting history.
7. **Never expose secrets.** Browser code uses only public configuration. Service-role credentials, Gmail credentials and GitHub secrets stay in server-side secrets.
8. **Do not touch unrelated dirty files.** Stage files deliberately; never bulk-add a workspace just to commit one change.
9. **Do not write to Google Sheets for DEN work.** Do not recreate retired sync/writeback paths.
10. **The user’s current explicit instruction overrides stale docs and earlier assumptions.** Flag a genuine conflict; do not quietly choose a convenient interpretation.

## 3. Mandatory orientation before work

Start in the workspace root, `C:\Users\mikit\Documents\Vinted`.

Read these files in full before non-trivial FADEWELL work:

1. `AGENTS.md`
2. `docs/core/CURRENT_STATE.md`
3. `docs/core/SOURCE_OF_TRUTH.md`
4. `docs/core/AI_OPERATING_RULES.md`
5. `docs/core/LIVE_VERIFICATION_PROTOCOL.md`
6. `docs/core/COMPACTION_POLICY.md`
7. `docs/core/DECISION_LOG.md`
8. `docs/core/WORKSPACE_INDEX.md`

Then use `WORKSPACE_INDEX.md` to identify task-specific material. For HQ changes, also read this guide, the affected source files, applicable migrations and tests. Use the live bridge at session start when available, but direct repository and live-source verification remain required.

### Important document conflicts

`OPERATING_MODEL.md` and `MIGRATION_TO_HQ.md` may contain migration-era wording. They are useful history, not permission to undo the HQ cutover. Never alter them merely to resolve a wording conflict unless the user asks.

## 4. Architecture at a glance

| Layer | Role | Authority / safety boundary |
| --- | --- | --- |
| `web/` | Static HQ interface published through GitHub Pages | Reads/writes HQ through authenticated Supabase RPCs; no private secrets |
| Supabase | Canonical business store, row-level security, RPCs, migrations | All accounting and DEN mutations are explicit, auditable database operations |
| `cloud/` | Collectors, normalizers and controlled backfills | Observes external data; must fail safely and leave review work visible |
| GitHub Actions | Runs Vinted snapshot collection and deploys Pages | Scheduled collection is best-effort; a healthy UI is not proof of a fresh collector |
| Gmail intake | Turns Vinted transaction mail into evidence or review work | Ambiguous mail never becomes a sale automatically |
| `scripts/` / tests | Local validation and operational utilities | Use only after checking scope and inputs |

Repository: `PanDory1992/fadewell-hq`. The branch and pull-request workflow are part of the release process; do not use the deprecated local mirror as a Git source.

## 5. Canonical business model

### Item identity

- `item_id` / `DEN-xxx` is the permanent internal item identity.
- `vinted_listing_id` identifies a specific Vinted listing when known.
- `live_title` is the verified title observed from the current Vinted listing.
- The original ledger/import title remains useful provenance; do not erase it just because a live title arrives.

### Display-title rule

Use the most useful verified title without breaking identity:

1. current `live_title` from Vinted;
2. a safely imported/recorded title;
3. a neutral fallback containing the DEN.

For unlisted items, keep the existing title or a purchase-mail-derived title. Do not fabricate a better title before a listing exists. When an item becomes listed, its verified Vinted title may replace the operational display title across Ledger, Home, Live Wardrobe, Pricing, Finance, Sourcing and search.

### Ledger and event history

The item record holds current state. The event log holds the durable explanation of how it changed. Important business events include purchase, listing, price change, snapshot observation, correction, sale and Gmail resolution.

Use append-only/audited events for a human decision wherever the data model supports it. Do not silently overwrite a business fact that needs a timeline.

### Statuses

Treat the database schema and current UI/RPC definitions as authoritative for exact status names. Conceptually:

- **unlisted / to list**: owned but not currently live;
- **listed / live**: an active Vinted identity is known;
- **sold**: sale has an explicit reliable source or human confirmation;
- **exception / review**: HQ has evidence but cannot safely determine the accounting action.

## 6. Evidence and confidence model

HQ separates observation from decision:

- **Observation:** Vinted snapshot, Gmail message, imported historic data, source URL, image/title capture.
- **Decision:** user-confirmed correction, explicit link, manual sale, manual allocation, approved resolver match.

An automation can enrich a record only at the confidence permitted by the evidence. For example, title-derived DNA is useful metadata, but must carry source/confidence and must not overwrite explicit human DNA. A suggested resolver match is a review item until its safety conditions are met.

## 7. What each HQ page is for

| Page | Read it for | Change it through |
| --- | --- | --- |
| Home | current operating picture, key actions and recent live stock | links to the responsible module |
| KPI | operational counts and trends | derived data only |
| Ledger | canonical items, bookkeeping state and item detail | Action Studio or explicit ledger actions |
| Item DNA | structured item facts and their provenance | DNA editor; preserve explicit human fields |
| Pricing | action queue for live listings and estimate rationale | pricing settings/actions only when explicitly supported |
| Finanse | cashflow, capital, realized/estimated margin and risk | derived canonical HQ ledger data |
| Sourcing | evidence-backed purchase segments and safe buy thresholds | derived data; no fake certainty for small samples |
| Live Wardrobe | current public Vinted listings and observed signals | Vinted remains the place to change a listing |
| Operations | collector, Gmail, resolver, queue and error health | reviewed operational actions and links |
| Action Studio | intentional purchase, listing, sale and correction actions | validated audited forms/RPCs |
| System | system diagnostics, integrity and deployment context | read-only unless an explicit operational control exists |

## 8. Core workflows

### A. Purchase

1. Receive a complete, trustworthy purchase record or a human-entered purchase.
2. Create one DEN per actual item.
3. For bundles, allocate the total cost explicitly across items (equal split only when the user asks for it or no better allocation exists).
4. Record evidence and the allocation rule.
5. If the mail is incomplete or ambiguous, create review work rather than phantom DENs.

### B. Listing and title enrichment

1. A listing is created on Vinted outside HQ.
2. The collector sees the listing and obtains listing ID, title and public state.
3. HQ safely links it to a DEN using explicit identity/evidence; it must not guess a risky match.
4. For listed items only, title/live data may enrich missing DNA fields such as model, colour, condition, era or origin when the evidence is reasonably clear.
5. Preserve source (`vinted_title`, live observation, human) and do not overwrite human-entered DNA with a weaker inference.

### C. Vinted collection

The collector is read-only. It captures current listing visibility, price, likes/views where available, title and other public signals into snapshots. It has integrity checks and retries so a partial scrape cannot silently become the new global truth.

When diagnosing freshness, inspect Operations and the workflow run; do not rely on a green label alone. A missing item can be a collector issue, an identity issue, a private listing or a real delisting.

### D. Gmail transaction intake

Gmail is evidence intake, not an accounting shortcut:

- complete purchase receipts can create or prepare purchase work only when item identity and allocation are safe;
- ambiguous messages stay in the review queue;
- a `SALE_PENDING` message is **not** a sale until an operator selects the correct listed DEN, enters/validates the sale amount and explicitly records it;
- an `UNCLASSIFIED` item can be closed as not relevant to DEN without changing the ledger;
- every resolution leaves an auditable event connected to the source message.

Never auto-sell an item because a Vinted listing disappears or a mail merely resembles a sale notification.

### E. Sales

1. Use confirmed Vinted/Gmail evidence or an explicit user confirmation.
2. Match against the correct DEN and listing identity.
3. Record gross amount, relevant dates/evidence and any necessary correction through the supported action.
4. Let HQ calculate the derived margin from canonical capital; do not hand-edit historical totals.

## 9. DNA, estimates and decision tools

DNA is structured, evidence-aware item knowledge: brand, model, tagged size, measurements, authenticity, condition, production/origin, fit/cut, era, material, wash/colour and related fields.

DNA improves comparability. It is not an excuse to claim precision the data cannot support.

- **Pricing estimates** combine comparable sold/current records, live-market signals, capital and confidence. Explain the reason, evidence and uncertainty.
- **Finance** distinguishes realized figures from estimates and labels source/reconciliation differences rather than hiding them.
- **Sourcing** aggregates actual HQ outcomes into segments. Low sample size must produce “insufficient evidence,” not a purchase rule.

Do not resurrect the old universal tier as a decision authority. Use concrete DNA and evidence where available; tier-like groupings may remain descriptive only if clearly labeled.

## 10. Authentication, permissions and secrets

- The HQ owner signs in with GitHub OAuth and ownership is claimed through the approved `claim_first_hq_owner` flow.
- Browser reads and mutations must be constrained by Supabase RLS and owner RPCs.
- The public Supabase URL/anon key may be present in the built client only when configured as public values.
- Service-role keys, Gmail access/refresh tokens, GitHub tokens and private configuration belong in secrets/environment only. Never commit, print or paste them into a client asset, issue, PR or handoff.
- When adding a migration, validate its RLS, grants, owner checks and audit effects—not only whether it runs.

## 11. Safe implementation and release protocol

### Before editing

1. Inspect `git status --short` and preserve unrelated work.
2. Read the affected implementation, tests, current migration state and UI path.
3. Determine whether the change is UI-only, database-only, automation-only or end-to-end.
4. Make the smallest complete change. Add a migration for durable schema/RPC/policy changes; do not patch production data ad hoc.

### Validation minimum

Run the relevant tests and checks. The standard HQ suite commonly includes:

```powershell
node web/item-title.test.mjs
node web/pricing.test.mjs
node web/sourcing.test.mjs
python -m unittest cloud.test_vinted_snapshot_sync cloud.test_backfill_vinted_titles
git diff --check
```

Also run the focused test for the changed subsystem. For a browser bundle, extract/check the inline script syntax if the project uses that validation pattern. For migrations, apply only approved migrations, then check the remote migration list and the affected RPC/table behavior.

### Database changes

- Migration files live under `supabase/migrations/` and must be ordered and idempotent where the project convention permits.
- Prefer the project’s existing Supabase CLI path, commonly:

```powershell
npx.cmd --yes supabase@latest db push
npx.cmd --yes supabase@latest migration list
```

- Never run destructive schema/data commands unless explicitly authorized and the target has been verified.
- Verify both deployment and behavior: SQL success alone is insufficient.

### Publishing

1. Stage only the files belonging to the task.
2. Commit with a precise message.
3. Push the working branch, open/update the PR, inspect its diff and checks, then merge only with user authorization or an established explicit release instruction.
4. Verify the GitHub Pages deployment and the live behavior at `https://hq.fadewell.eu` for UI changes.
5. For a docs-only change, verify the pushed commit/PR; a Pages deploy is not a functional requirement unless a web asset changed.

After consequential work, update the appropriate durable workspace state according to `AI_OPERATING_RULES.md` and post a concise live-bridge handoff: what changed, evidence, next action and blocker if any.

## 12. Fast diagnosis guide

| Symptom | First checks | Safe interpretation |
| --- | --- | --- |
| Listing count differs from “listed” count | Operations freshness, snapshot integrity, canonical item/listing mapping | Different metrics may count different entities; do not force equality without definition |
| Item is missing from collector output | listing ID, live Vinted visibility, latest collector error and mapping | Not proof of sale |
| Purchase mail created no DEN | Gmail classification, completeness, bundle parsing and review queue | likely held for safe review, not silently lost |
| Gmail card has no action | check Operations review state and action affordance | fix UI wording/link or add an explicit audited resolution, not a hidden mutation |
| Title looks like an old Sheet shorthand | check `live_title`, listing ID and latest Vinted snapshot | update from verified live listing only; unlisted items retain existing title |
| Estimate seems wrong | inspect comparable evidence, DNA completeness, capital, confidence and sample size | improve explanation/data quality before tuning an opaque number |

## 13. File map

```text
fadewell_hq/
  AI_README.md                 # this guide
  README.md                    # project-level setup/readme
  web/                         # Pages client, UI and browser tests
  cloud/                       # collector, backfills and cloud tests
  supabase/migrations/         # schema, RPC, RLS and audit evolution
  scripts/                     # operational utilities
  .github/workflows/           # collector and Pages deployment workflows
```

The parent workspace owns cross-project governance under `docs/core/`. Do not copy it into code comments or bypass it; link to the canonical rule instead.

## 14. Definition of done

A HQ change is done only when it is:

- correctly scoped and does not include unrelated local changes;
- tested at the changed layer and checked for regressions;
- migrated and behavior-verified when it changes Supabase;
- pushed/reviewed/merged according to the release instruction;
- live-verified when it changes live UX or automation;
- reflected in the appropriate durable state and bridge handoff when consequential;
- explainable to the operator: what happened, why, what evidence supports it, and what remains uncertain.

When uncertain, choose the safer path: preserve evidence, create review work, and ask before making an irreversible business claim.
