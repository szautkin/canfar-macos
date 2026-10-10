# Search

CADC's archive: the form, ADQL, the results table, an observation's detail.

- **The search.** `SearchFormModel` runs it; one search at a time, and its `Readiness` says whether the
  table holds what was last asked. `SearchResultsModel` is the table: filters, sort, pages, units.
- **CADC's services.** `TAPClient` (TAP, VizieR, the resolver), `CAOM2Service`, `DataTrainService` and
  `TapSchemaService`.
- **`SavedQueryStore` and `RecentSearchStore`** keep what the person runs again (the last 100 recent
  ones).
- **`MCP/`.** The tools, and their wiring in four `AppState+Search…` files by job: the archive, queries,
  the form, the results.
- **`Sync/`** holds the saved queries' and recent searches' adapters.
