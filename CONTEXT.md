# SkyPoints Member Data

Daily ingestion of SkyPoints loyalty-program member profiles and partner-airline redemptions, split into per-country member tables.

## Language

### Members

**Member**:
A person enrolled in SkyPoints, identified solely by their Member ID. The name is a mutable attribute, not an identity.
_Avoid_: Customer, passenger, account

**Member ID**:
The natural key of a Member. The source spec's "Key Column" flag on Member Name is treated as an error.
_Avoid_: Mem_Id, member number

**Member Record**:
One detail (`D`) row for a Member in one Member File. A Member may have many Member Records across files, or even within one file.
_Avoid_: Row, profile

**Current Member Record**:
The latest Member Record for a Member: ordered by the Member File's business timestamp, ties broken by line number within the file.
_Avoid_: Latest row, active record

**Country Move**:
When a Member's Current Member Record names a different country than before. The Member then leaves the old country table; a Member belongs to exactly one country table at a time.
_Avoid_: Relocation, transfer

**Country**:
A country identified by its ISO 3166 alpha-3 code. Source country values are variants that map onto exactly one Country through the Country Reference.
_Avoid_: County, region, raw country code

**Country Reference**:
The authoritative list of Countries: each one's accepted source variants and its Country Table.
_Avoid_: Country lookup, mapping file

**Member Hub**:
The single table of every Member's Current Member Record across all Countries. Country Tables are derived from it, and Redemptions join to it.
_Avoid_: Master table, golden record

**Country Table**:
The physical table holding the Current Member Records of every Member in one Country (e.g. `Table_India`), derived from the Member Hub.
_Avoid_: Country view, partition

**Business Date**:
The date a Member File or Redemption Feed is for, taken from its filename (`SKYPOINTS_<FEED>_YYYYMMDD_HHMMSSTT`, where TT is hundredths of a second). Age and Stale Member are computed as of this date.
_Avoid_: Load date, run date, today

**Age**:
A Member's whole years completed between Date of Birth (MMDDYYYY) and the Business Date.

**Stale Member**:
A Member whose Last Flight Date is more than 90 days before the Business Date.
_Avoid_: Inactive member, which is the source's separate Active Member flag

### Data quality

**Reject**:
A Member Record that fails an error-severity check (missing mandatory field, unparseable Enrollment Date, missing or unmapped country). It is held in the rejects table with a reason code and never reaches a Country Table.
_Avoid_: Bad row, error record

**Warning**:
A suspicious but loadable Member Record (e.g. a short Member ID, a future DOB, Last Flight Date before Enrollment Date). It loads and carries a flag.
_Avoid_: Soft error

**Reject Threshold**:
The maximum share of Rejects in one Member File. Above it, the whole batch fails.

### Redemptions

**Redemption**:
One partner-airline mileage redemption, identified by its `txn_id`. Its current status is the one from the latest Redemption Feed (by feed date).
_Avoid_: Transaction, txn

**Redemption Event**:
One sighting of a Redemption in one Redemption Feed. Every status change is a new Redemption Event.

**Orphan Redemption**:
A Redemption whose Member ID matches no known Member. It is kept and flagged, not dropped.

### Feeds

**Member File**:
The daily pipe-delimited flat file of Member Records, with one header (`H`) row. It is a delta: it carries only new or changed Members, so a Member's absence means "unchanged", never "removed".
_Avoid_: Profile feed, flat file

**Redemption Feed**:
The daily semi-structured JSON feed of partner-airline mileage redemptions.
_Avoid_: JSON file, transaction feed
