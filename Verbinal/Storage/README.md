# Storage

The person's VOSpace (CANFAR's `/arc`): browsing, moving files, sharing.

- **`VOSpaceBrowserService`** is the one client of the wire.
  - `ensureFolder` asks before it makes a folder.
  - Every change goes through the change log.
- **`ResultUpload`** puts a file the app wrote into storage: `Verbinal-Exports/` by default.
  `ResultDestination` uses it for the person's results.
- **`MCP/`** holds the storage tools, the storage quota, and the Windows names of two tools
  (`StorageAliases`).
- **Sharing is the person's.** A tool that changes who may read a folder always waits for them.
