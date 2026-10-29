# Plan 54 — Every result row a product: publisherID always, and search tools that say so

**Status: built on branch `1_4_2` (2026-10-28), committed 2026-10-29. Live cases L1–L4 are left.** History:
- Planned 2026-10-28.
- The person said "double check the field name publisherID in the CADC tap schema .... and proceed", then
  asked "caom2.Observation?". The recommended answers D1–D4 were taken, with B3 refined for observations
  (below). What was built, and where it differs from this plan, is in "Where it stands".

The person (2026-10-28): "improve the related search mcp tools, and make it mandatory to include
publisherID field in the search result fields (check the tap schema properly), so, in the table we can
fetch previews and metadata... review and plan".

## What the TAP schema says

CADC's `tap_schema.columns`, asked on 2026-10-28:

| Table | Column | utype | UCD | What it is |
|---|---|---|---|---|
| `caom2.Plane` | `publisherID` | `caom2:Plane.publisherID` | — | "unique publisher identifier for this product"; principal, indexed |
| `ivoa.ObsCore` | `obs_publisher_did` | `obscore:Curation.PublisherDID` | `meta.ref.ivoid` | the same identifier, in ObsCore |
| `caom2.SIAv1` | `publisherDID` | — | `VOX:Image_Title` (sic) | the same, in the SIA view |
| `caom2.Observation` | `observationURI` | `caom2:Observation.uri` | — | not a product's: one observation has many products (planes) |
| `caom2.Artifact` | — | | | a file of a plane; joins to it by `planeID` |

The identifier is a product's (a plane's), not an observation's. DataLink (previews, thumbnails,
files), CAOM2 metadata and downloads all take it.

### Double-checked against Argus (2026-10-28)

- **The exact name is `caom2.Plane.publisherID`:** `char(*)`, principal, indexed, utype
  `caom2:Plane.publisherID`.
  - A value: `ivo://cadc.nrc.ca/CFHT?1227446/1227446g`.
  - Identifiers are case-insensitive (`p.publisherid FROM caom2.plane` works), but the output header
    echoes what was written.
- **The other identifier columns.** No other `caom2` or `ivoa` table has a publisher column but
  `ivoa.ObsCore.obs_publisher_did` (`char(256*)`) and `caom2.SIAv1.publisherDID` (`char(128*)`).
  `obs_publisher_did` is the same value as `Plane.publisherID` (checked by joining them).
- **`caom2.Observation` has no `publisherID`.** Its identifier is `observationURI` (`caom:CFHT/1227446`;
  utype `caom2:Observation.uri`; principal, indexed, standard). One observation has several products:
  `1227446` has `…g`, `…o`, `…p`.
  - CAOM2 metadata takes the observation URI, and answers with all its planes.
  - DataLink does not take it: one empty row, against six (thumbnail, two previews, the file) for a
    product's `publisherID`.

## What the review found

1. **Results find the identifier only by a header that cleans to `publisherid`.**
   - "Publisher ID", which the form's query uses, and a bare `publisherID` work.
   - These do not:
     - ObsCore's `obs_publisher_did`, which cleans to `obspublisherdid`;
     - SIAv1's `publisherDID`, which cleans to `publisherdid`;
     - any other alias.
   - Such rows show no preview, no DataLink and no metadata, and cannot be downloaded. Their id falls
     back to `obsid` or the row's place (`SearchResultsModel.rowID`, `ObservationDetailModel.publisherID`,
     `PreviewThumbnailCell`, `SearchResultsText`).
2. **Nothing makes a query select it.**
   - The form's query does (`ADQL.selectColumns`).
   - These may not:
     - the person's own ADQL;
     - an assistant's `set_adql_query` and `execute_adql_query`;
     - `search_observations` with ADQL;
     - a saved or recent query.
   - Nothing says so when they do not.
3. **The schema loader reads `ucd` but not `utype`.** It cannot find the identifier column by what it
   means (`TapSchemaService.fetch`).
4. **`search_observations` returns raw `headers` and `rows`.** An assistant must guess which column
   identifies a product before it can call `get_preview_image`, `get_data_links` or
   `get_observation_caom2`, which all take `publisher_id`.
5. **`get_search_results` has `rowIDs`** (the identifier when there is one, else `obsid` or `row_N`)
   without saying which it is.
6. **`validate_adql_query` and the ADQL editor's checker say nothing** of a query without the
   identifier. `describe_tap_schema` does not name it per table.
7. **What already helps:**
   - every CADC archive query goes through `TAPClient.tapQuery(adql:)` or `tapQueryRows(adql:)`, one
     place to make sure (VizieR has its own path, which is not CAOM and stays as it is);
   - `ADQLValidator` already tokenizes a query and parses its FROM tables and aliases.

## Principles

- **A row is a product.** Every archive query that returns products returns their identifier, whoever
  wrote it.
- **By meaning, not by name.** The identifier column is found from the TAP schema (utype), with the
  three names above as the fallback when the schema is not loaded.
- **What runs is what is shown.** A column Verbinal adds appears in the query the person or the
  assistant sees.
- **Said, not silent.** When a query cannot have the identifier, the editor, the checker and every tool
  say why, and what to join.

## A. The identifier, by meaning

- **A1.** `TapSchemaService` reads `utype` too. `TapSchema.Column` gains it.
- **A2.** `ResultIdentifier.column(of:schema:)` is the column whose utype is `caom2:Plane.publisherID`
  or `obscore:Curation.PublisherDID` (a product), else `caom2:Observation.uri` (an observation). Without a
  schema, or a table without utypes, the fixed map:
  - `caom2.Plane` → `publisherID`;
  - `ivoa.ObsCore` → `obs_publisher_did`;
  - `caom2.SIAv1` → `publisherDID`;
  - `caom2.Observation` → `observationURI`.

## B. Every product query selects it

`ADQLIdentifier.ensure(adql, schema) -> (adql, identifier: OutputColumn?, note: String?)`, at the one
place archive queries go (B6).

- **B1. Which query it applies to.** For each FROM table (with its alias) that has an identifier column:
  if the select list has neither that column (`alias.col`, or a bare `col` when only one table has it),
  nor `*`, nor `alias.*`, it appends `alias.col AS "Publisher ID"`.
- **B2. Not where rows are not products.** `DISTINCT`, `GROUP BY` and aggregate functions are left as
  they are. The answer notes that they have no identifier.
- **B3. A query of observations, not products** (Observation without Plane): Plane is not joined, as that
  would change its rows. Instead it makes sure of the observation's identifier,
  `Observation.observationURI AS "Observation URI"`, so its details open (CAOM2 metadata takes it). The
  note gives the join for products, previews and downloads:
  `JOIN caom2.Plane AS Plane ON Plane.obsID = Observation.obsID`.
  - A query with neither (Artifact only) is not rewritten, and the note says so.
- **B1a. "Already selected" means a header the table recognizes:** `publisherID`, `publisherDID`,
  `obs_publisher_did`, "Publisher ID", or `observationURI` and "Observation URI". An identifier selected
  under another alias gets the recognized one added too.
- **B4. Which output column is the identifier.** The alias or name of the identifier's select item,
  added or the person's own, goes with the results (C1). Headers are then never guessed.
- **B5. What runs is shown.** The ADQL editor's text becomes the query that ran (D1). An assistant's
  answer carries the query as run.
- **B6. Where.** `TAPClient.tapQuery(adql:)` and `tapQueryRows(adql:)` (CADC archive). Never
  `tapQueryAt` for VizieR.

## C. The table uses it, whatever it is called

- **C1.** `SearchResultColumns` knows its identifier column (B4). It falls back to the known names:
  `publisherid`, `publisherdid`, `obspublisherdid`.
- **C2.** These read the identifier through it:
  - `SearchResultsModel.rowID` and `result(publisherID:)`;
  - `ObservationDetailModel.publisherID`;
  - the Preview cell;
  - `SearchResultsText`.
- **C3.** Results with no identifier say so above the table: "These results have no publisher ID:
  previews, details and downloads need caom2.Plane", with the join from B3.

## D. The search tools

- **D1. Each row of `search_observations` and `get_search_results` carries its `publisherID`.** It is a
  field of its own, or null with a `note` saying why. The answer names `identifierColumn`.
- **D2. The query tools say what they did.**
  - `execute_adql_query`, `set_adql_query`, `run_saved_query` and `load_saved_search` say when the
    identifier was added.
  - `validate_adql_query` says when it cannot be added (B2, B3), with the join.
- **D3. `get_preview_image`, `get_data_links`, `get_observation_caom2` and `show_observation_detail`**
  also take `row` (1-based, in the current results) instead of `publisher_id`. An assistant need not
  copy ids, and is told when that row has none.
- **D4. `describe_tap_schema` names each table's identifier column** and what takes it (DataLink,
  previews, metadata). The tool descriptions say every product query returns `publisherID`.

## E. The editor, the manual, parity

- **E1. The ADQL editor's checker shows "No publisher ID"** for B2 and B3, with a **Join Plane** fix
  for B3 (D3).
- **E2. Manual chapter 2 (en, fr):** product rows always have their publisher ID, and why a query
  without one shows no previews.
- **E3. Parity rows** for D1–D4.

## Decisions for the person

- **D1. Show the added column in the ADQL editor?**
  - (a) Yes: the editor's text becomes the query that ran. **Recommended.**
  - (b) No: add it only on the way to CADC.
- **D2. Aggregates, DISTINCT, GROUP BY.**
  - (a) Leave them, with a note. **Recommended:** their rows are not products.
  - (b) Refuse them.
- **D3. Observation-only queries.**
  - (a) Do not join, but say how; the editor offers **Join Plane**. **Recommended.**
  - (b) Join Plane automatically, which changes one row per observation into one per product.
- **D4. `row` as well as `publisher_id` in the per-product tools.** **Recommended: yes.**

## Steps (tests first)

1. A: `utype`, and `identifierColumn` for Plane, ObsCore, SIAv1 and Observation, with and without a
   schema.
2. B: `ADQLIdentifier.ensure`.
   - Tests:
     - the form's query is unchanged;
     - `SELECT Plane.productID FROM caom2.Plane` gains it, and so does an aliased Plane;
     - ObsCore gains `obs_publisher_did`;
     - `SELECT *` is unchanged;
     - DISTINCT, GROUP BY and COUNT are unchanged, with a note;
     - Observation-only is unchanged, with the join;
     - comments and quoted names are not touched.
   - Then wire it into `TAPClient`.
3. C: the identifier column in the results model and views.
   - Tests: rows of an ObsCore query have previews; an aliased identifier is found.
4. D: the tools' outputs and arguments; descriptions; the guardrail tests.
5. E: the editor's checker and **Join Plane**; manual; parity.

## Live cases

- **L1.** The person's ADQL `SELECT TOP 10 Plane.productID, Observation.collection FROM caom2.Plane
  JOIN caom2.Observation …` shows `Plane.publisherID AS "Publisher ID"` added, and previews load.
- **L2.** An ObsCore query shows previews and opens details.
- **L3.** An Observation-only query says how to join Plane, and **Join Plane** does it.
- **L4.** An assistant runs `search_observations` with its own ADQL and gets each row's `publisherID`; it
  runs `execute_adql_query`, then `get_preview_image(row: 0)` shows the first row's preview.

## Where it stands (2026-10-28)

Built as planned, with these differences:
- **B4–B6. Where it runs.** Not inside `TAPClient`, which the data train and the schema loader share, but
  where a query someone wrote runs: `SearchFormModel.executeRawQuery` (the editor, an assistant's
  `set_adql_query` and `execute_adql_query`, saved and recent queries) and `search_observations`. The
  form's query has it already. `SearchFormModel.identified(_:)` is the one call.
- **C1. By name, never guessed.** Since a query that runs always has a recognized header (B1a), the
  results find it by `ResultIdentifier.of(header:)`: `SearchResultColumns.identifier`, `publisherID(in:)`
  and `metadataID(in:)` (the observation URI when there is no publisher ID, for CAOM-2). Every
  `"publisherid"` lookup reads through them.
- **D2.** `set_adql_query`, `execute_adql_query`, `validate_adql_query` and `search_observations` answer
  with `identifier` (`identifies`, `added`, `note`, `join`). `run_saved_query` and `load_saved_search`
  answer at once, before the query runs; `get_search_results` then says it, with `publisherIDNote`.
- **D3. `row` is 0-based on the page shown**, as `show_search_row_detail` already took it: one meaning of
  "row". `get_preview_image`, `get_data_links` and `get_observation_caom2` take it
  (`ProductReference`); `show_observation_detail`'s row form is `show_search_row_detail`.
  `get_observation_caom2` given a row of observations uses its URI.
- **D4.** `describe_tap_schema` gives each table `identifierColumn` and `identifies`.
- **E1.** The note shows under the editor (`IdentifierGapNote`) for any gap, with **Join Plane** for
  observations and artifacts (`ADQLIdentifier.joining`: before the query's own WHERE, GROUP BY, HAVING
  or ORDER BY, else at the end). Above results, the same note without the button.

Tests: `ADQLIdentifierTests` (16) and `PublisherIDResultsTests` (9).
