# SkyPoints ETL

Daily ingestion of the SkyPoints loyalty program's two feeds into Snowflake:

- a pipe-delimited **Member File** of member profiles, split into one table per country with
  "latest record wins" when a member moves;
- a newline-delimited JSON **Redemption Feed** of partner-airline mileage redemptions, flattened
  and joined back to members.

The vocabulary used throughout (Member, Member Record, Business Date, Reject, Country Move…) is
defined in [CONTEXT.md](CONTEXT.md). The three decisions most likely to surprise a reader are
recorded in [docs/adr](docs/adr). The brief is in [docs/](docs/).

## Flow

```
            PUT                 COPY (Task)            SP_LOAD_MEMBER_BATCHES
 files ──► @STG_INBOUND ──► LND_MEMBER_FILE ──stream──► FILE_BATCH (register, header check)
           member/          (raw text lines)            WRK_MEMBER_PARSED (by-name parse, type,
           redemption/                                    Age, Stale, errors/warnings)
                                                         ├─► MEMBER_REJECTS
                                                         └─► STG_MEMBER (append-only history)
                                                                   │ stream
                                         SP_MERGE_MEMBER_HUB       ▼
                                         latest record wins ─► MEMBER_HUB (1 row per Member_Id)
                                                                   │ stream (old + new row images)
                                         SP_REFRESH_COUNTRY_TABLES ▼
                                         TABLE_USA · TABLE_INDIA · TABLE_PHILIPPINES · TABLE_CANADA · TABLE_AUSTRALIA

                        COPY             SP_LOAD_REDEMPTION_BATCHES      SP_MERGE_REDEMPTIONS
 @STG_INBOUND/redemption ──► LND_REDEMPTION_FEED ──stream──► REDEMPTION_EVENT ──stream──► REDEMPTION_CURRENT
                             (raw JSON lines)    TRY_PARSE_JSON + FLATTEN   (status history)     (latest per txn_id)
                                                 └─► REDEMPTION_REJECTS
                                                                                   V_REDEMPTION_ENRICHED
                                                       REDEMPTION_CURRENT ⟕ MEMBER_HUB on member_id
```

`SP_RUN_PIPELINE` runs every step and then `SP_RUN_DQ_CHECKS`. `TASK_SKYPOINTS_DAILY` calls it on
a schedule. It is created suspended.

## Deliverables

| # | Deliverable | Where |
|---|---|---|
| 1 | DDL: landing, staging, country targets | [`20_landing.sql`](sql/20_landing.sql), [`21_staging.sql`](sql/21_staging.sql), [`22_core.sql`](sql/22_core.sql); Country Tables are generated from `COUNTRY_REF` by `SP_ENSURE_COUNTRY_TABLES` in [`42_proc_country_tables.sql`](sql/42_proc_country_tables.sql) |
| 2 | Staging with Age and Stale_Member | [`40_proc_member_load.sql`](sql/40_proc_member_load.sql) |
| 3 | Per-country split, latest record wins | [`41_proc_member_hub.sql`](sql/41_proc_member_hub.sql), [`42_proc_country_tables.sql`](sql/42_proc_country_tables.sql) |
| 4 | Flatten JSON, join to members | [`43_proc_redemption.sql`](sql/43_proc_redemption.sql), [`60_views.sql`](sql/60_views.sql) (join explained below) |
| 5 | Data validations | load-time checks in `40_`/`43_`, post-load invariants in [`50_dq_checks.sql`](sql/50_dq_checks.sql) |
| 6 | Live demo | [Running it](#running-it) |

## Key rules and assumptions

These were settled before building. The spec is ambiguous or contradictory on each.

- **Member_Id is the key.** The spec marks Member Name as the key column. Names aren't unique
  and they change, so the spec is treated as wrong on this point.
- **Latest record wins means latest file, then latest line.** Files are ordered by the timestamp
  in their name (`SKYPOINTS_<FEED>_YYYYMMDD_HHMMSSTT`), and lines within a file by line number.
  A late-arriving *older* file never overwrites a newer record.
- **A Country Move removes the member from the old Country Table** in the same transaction. A
  member is never in two tables. Every version stays in `STG_MEMBER`.
- **The Member File is a delta.** A member missing from a file is unchanged, not deleted.
- **Age and Stale_Member are computed as of the file's Business Date**, not today
  ([ADR 0003](docs/adr/0003-business-date-as-of.md)). That keeps runs reproducible.
  `V_MEMBER_CURRENT` adds `age_today` / `is_stale_today`. Stale means Last Flight Date is more
  than 90 days before the Business Date (configurable). No flight date gives a NULL flag, not a
  guess.
- **DOB is MMDDYYYY**, a US-style format matching the sample's USA member. Other dates are
  YYYYMMDD.
- **Countries are normalised to ISO alpha-3** through `COUNTRY_ALIAS` (`AU`→`AUS`, `PHIL`→`PHL`,
  `CA`→`CAN`, …). An unmapped or missing country is a Reject, because the member can't be routed
  to any table. Adding a country is two reference rows; its table is created on the next run.
- **Physical per-country tables**, as the brief asks, generated from reference data
  ([ADR 0001](docs/adr/0001-generated-per-country-tables.md)). They sit downstream of the
  **Member Hub** ([ADR 0002](docs/adr/0002-member-hub.md)).
- **Bad rows are quarantined, not fatal.** Rejected rows go to `*_REJECTS` with reason codes and
  the rest of the file loads. A file whose reject rate exceeds `MEMBER_REJECT_THRESHOLD`
  (default 5%, in `PIPELINE_CONFIG`) fails whole.
- **Redemptions are keyed by `txn_id`.** The latest status wins by feed date, and the full
  history is kept.

## Data issues in the sample, and what catches them

| Issue in the brief's sample | Handling |
|---|---|
| Key column is Member Name, not Member ID | Member_Id is the key; `HUB_DUPLICATE_MEMBER_ID` invariant |
| Layout lists **Post Code**, but the header and data have no such field | Columns are located **by header name**. Optional Post_Code is NULL when absent. A header missing a *required* column rejects the file (`HEADER_MISSING_COLUMNS`), so nothing is silently shifted |
| Country codes mixed: `USA`, `IND` (ISO-3), `CAN`, `AU` (ISO-2), `PHIL` (neither) | `COUNTRY_ALIAS` → ISO-3; `COUNTRY_UNMAPPED` / `COUNTRY_MISSING` rejects |
| Staged DOB `3051985`: the leading zero was lost by an integer cast | Everything lands as text. Dates must be exactly 8 digits before parsing, giving `DOB_INVALID` (a warning, since DOB is optional) instead of a misread date. Post Code is stored as text for the same reason |
| Member IDs `22345`, `2256` are shorter than the rest | `MEMBER_ID_SHORT` warning (the spec gives only a maximum length) |
| Staging table lost Agent_Name for 4 of 5 rows | Batch reconciliation (`total = loaded + rejected`, staged rows = loaded count). Loading through one typed, by-name parse leaves no column-mapping step to lose a field |
| Staging column labelled `County` | Staging schema is defined once, in DDL, from the layout |
| Ambiguous DOB (03/05 vs 05/03) | Documented assumption (MMDDYYYY); `DOB_IN_FUTURE`, `DOB_AFTER_ENROLLMENT`, `AGE_OUT_OF_RANGE` warnings catch swapped formats that produce impossible dates |
| Every member's last flight is in 2012 | Correctly all stale as of the Business Date; `LAST_FLIGHT_BEFORE_ENROLLMENT` / `…_IN_FUTURE` warnings |

## Validations

**File level** (the whole file is `REJECTED` and recorded in `FILE_BATCH`): name outside the
spec; header missing, duplicated, not first, missing required columns, unknown columns, or
duplicate columns.

**Record errors** (the record goes to `MEMBER_REJECTS` and counts toward the threshold):
mandatory fields missing (Member Name, Member ID, Enrollment Date); Enrollment Date unparseable;
country missing or unmapped; field count differs from header; record type not `D`; leading
delimiter missing; any field longer than the spec allows.

**Record warnings** (the record loads with codes in `dq_warnings`): short or non-numeric Member
ID; the same member twice in one file; DOB invalid, in the future, after enrollment, or age over
120; flight date invalid, in the future, or before enrollment; enrollment in the future; unknown
tier; Is_Active not `A`/`I`; non-numeric Post Code.

**Redemptions**: invalid JSON; record not an object; member_id or feed_date missing or invalid;
`redemptions` not an array; txn_id missing; txn_date invalid or after feed_date; miles not a
positive integer; unknown status. Warnings: partner missing; feed_date ≠ file date; txn_id
duplicated within a feed.

**Post-load invariants** (`CALL SP_RUN_DQ_CHECKS()`): key uniqueness in the hub and current
redemptions (Snowflake doesn't enforce PRIMARY KEY); the hub holds each member's latest staged
record; batch reconciliation; reference integrity; derived-flag consistency; and, per Country
Table, wrong-country rows, drift from the hub, and members present in more than one table.

`V_DQ_ISSUE_SUMMARY` counts every reject and warning code per file.

## Joining redemptions to members

Redemptions join to the **Member Hub on `member_id`**, not to the Country Tables:

```sql
SELECT rc.*, h.member_name, h.tier_code, h.country_code, h.member_id IS NULL AS is_orphan
FROM REDEMPTION_CURRENT rc
LEFT JOIN MEMBER_HUB h ON h.member_id = rc.member_id;      -- = V_REDEMPTION_ENRICHED
```

- The hub holds every member exactly once whatever their country. That makes this one
  equi-join, where the Country Tables would need a UNION of N tables that grows with each
  country, and it follows Country Moves for free.
- It's a **LEFT** join so that **orphan** redemptions, for members the profile feed hasn't
  delivered yet, stay visible and flagged. They resolve on their own once the member arrives.
- For history questions, `REDEMPTION_EVENT` joins to `STG_MEMBER` on `member_id` with the
  member version in force at `txn_date`.
- `V_MEMBER_REDEMPTION_SUMMARY` gives completed and pending miles per member.

## Built for volume

The brief says billions of records a day. The design choices that matter for that:

- **Incremental by construction.** Each step reads only new data through Snowflake Streams.
  Nothing rescans landing or staging. Each step runs in one transaction, so a failure leaves
  the stream offset where it was and a rerun is safe (the integration tests include an idle
  rerun).
- **Set-based, single pass.** Parsing, typing, derivation and every validation happen in one
  `INSERT … SELECT` per feed. There are no row-by-row loops. Country Tables are rewritten only
  for changed members, and only in affected countries.
- **Landing can't fail on content.** Both feeds land as raw text lines, so a bad row is a
  reject, not a failed COPY.
- **Clustering** on the columns each table is read by: staging by business date, the hub by
  country, current redemptions by member_id.

Measured on an **X-Small** warehouse: 1,000,000 members + 1,499,280 redemptions ran end to end
(ingest → DQ checks) in **67 seconds**, with injected defects correctly rejected and flagged.

At billions a day in production I would add:

- **Snowpipe auto-ingest** from S3/GCS/Azure instead of the scheduled COPY.
- Source files split into 100–250 MB compressed chunks so COPY parallelises.
- A larger or multi-cluster warehouse for the load window.
- A retention purge on landing.
- Search optimisation on `member_id` for point lookups.

## Running it

Needs [uv](https://docs.astral.sh/uv/). It installs Python 3.12 itself.

```bash
uv sync
```

Connection settings come from the environment and never live in the repo. Put credentials in
`~/.snowflake/connections.toml`:

```toml
[skypoints]
account  = "<account identifier>"
user     = "<login name>"
password = "<password>"
role     = "SYSADMIN"
```

```bash
export SNOWFLAKE_CONNECTION_NAME=skypoints
export SNOWFLAKE_WAREHOUSE=COMPUTE_WH
export SNOWFLAKE_DATABASE=SKYPOINTS_DEV       # must exist
export SNOWFLAKE_SCHEMA=SKYPOINTS             # optional; this is the default
```

Instead of a named connection you can set `SNOWFLAKE_ACCOUNT` and `SNOWFLAKE_USER`, plus
`SNOWFLAKE_PASSWORD`, `SNOWFLAKE_PRIVATE_KEY_FILE` or `SNOWFLAKE_AUTHENTICATOR`.

Demo:

```bash
uv run skypoints deploy                       # create/upgrade every object (idempotent)
uv run skypoints put data/samples/*           # the brief's sample files
uv run skypoints run                          # ingest + whole pipeline, prints a summary
uv run skypoints dq                           # post-load invariant checks

uv run skypoints generate --members 1000000 --timestamp 20240116090000 \
    --reject-fraction 0.01 --warning-fraction 0.02
uv run skypoints put data/generated/* && uv run skypoints run
```

Then, in Snowsight:

```sql
SELECT * FROM TABLE_INDIA;
SELECT * FROM FILE_BATCH ORDER BY batch_id;
SELECT * FROM V_DQ_ISSUE_SUMMARY;
SELECT * FROM V_REDEMPTION_ENRICHED;
ALTER TASK TASK_SKYPOINTS_DAILY RESUME;       -- to schedule it
```

## Tests

```bash
uv run pytest tests/unit                      # offline, < 1 s
uv run pytest tests/integration               # live Snowflake, ~2.5 min
```

- **Unit tests (80)** cover the file-name spec, the SQL splitter, the generator, connection
  settings, and static checks on `sql/`: deploy order, no schema-qualified names, every called
  procedure and every read stream is defined.
- **Integration tests (22)** deploy into a throwaway `SKYPOINTS_IT_<random>` schema and play a
  week of feeds: the country split and spelling normalisation, a Country Move, a late older
  file, a duplicate member within one file, Age and Stale boundaries (exactly 90 vs 91 days; a
  birthday on vs the day after the Business Date), the brief's lost-zero DOB, a
  threshold-breaching file, every reject reason, bad file names and headers, PENDING→COMPLETED
  redemptions, orphans, an idle rerun, and finally no broken DQ invariant. The schema is
  dropped afterwards.
- Integration tests skip automatically when no Snowflake settings are present.

## Known limitations

- A file whose name was already processed is ignored if it is landed again. Corrections should
  arrive as a new, later file.
- Country Tables are `LIKE MEMBER_HUB` when created. A later hub column change needs a matching
  `ALTER` on them.
- `HUB_NOT_LATEST_RECORD` scans all of staging. At scale it should be limited to recent batches.
- Rejects are kept with their raw line for replay. Replay itself is a manual re-send.
