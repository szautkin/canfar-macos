# StorageSync

Verbinal's data in the person's VOSpace, the same on every device (plans 34 V, 36 tier 3).

- **`StorageSync`.** An actor: one sync at a time. It reads the manifest only when it changed, and lists
  each declared kind's folder once. It never deletes.
  After a send it remembers only what it wrote; what another device wrote meanwhile is still to come
  (plan 44 A2).
- **`StorageKind`.** One per kind, and `StorageKindCatalog` lists them. `CollectionKind` is the one rule
  for the person's collections; the other kinds are `ImagePackagesKind`, `ComputeRunsKind`,
  `ResultsKind` and `CountedKind`.
- **`SyncItem`, `SyncCollection`, `SyncRecord` and `RecordCollection`** are what an area's adapter is
  made of.
- **`StorageSyncModel`** runs it in the app:
  - after sign-in, when the app comes back, and a few seconds after a chosen collection changes;
  - nothing for an account without CANFAR storage.
- **Settings ▸ Storage** has one switch for each collection, off until the person turns it on.
