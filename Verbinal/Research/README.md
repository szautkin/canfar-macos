# Research

The observations the person keeps, their files and their notes.

- **`ObservationStore`.** It owns the records. They are kept in the database by `ResearchRecords`, each
  whole under its key: the publisher ID, and which cutout. The JSON file of before is read in once and
  kept beside as `.migrated` (plan 36 5.1).
- **`ObservationNoteStore`.** It owns the notes, tags and ratings, in the database with a full-text
  index.
- **Placing files.** `ResearchFiles` and `DownloadPlacement` place a record's files in the person's
  download folder, and tell `ResultDestination`.
- **`ResearchFilter`.** It is one rule for the screen's filter and `list_downloaded_observations`.
- **`MCP/`** holds the Research, download and cutout tools.
- **`Sync/`.** `ResearchItem` and its adapter carry a record's details and note, never its files or
  paths.
