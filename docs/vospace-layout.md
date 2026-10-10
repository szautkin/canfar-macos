# Verbinal's data in VOSpace

What Verbinal keeps in the person's VOSpace home (`vos://cadc.nrc.ca~arc/home/<username>/`), and how
every Verbinal (macOS, Windows, Linux, and any later one) finds it and keeps it in step. Verbinal for
macOS reads and writes it from 1.4.1 (plan 34 V).

## The rule: one manifest of kinds

`.verbinal/manifest.json` says which **kinds** of Verbinal's data the person keeps in VOSpace, and
where each lives. It lists kinds, not items: a kind's folder holds its items, and the folder is their
inventory. Every Verbinal reads the manifest at sign-in to know what to sync; a kind declared from one
device is synced on all of them.

```json
{
  "format": "verbinal.vospace-manifest",
  "version": 1,
  "kinds": {
    "research":      { "folder": ".verbinal/research",  "format": 1, "since": "2026-10-08T14:02:11Z" },
    "imagePackages": { "folder": ".verbinal/manifests", "format": 1, "since": "2026-09-12T09:30:00Z" },
    "computeRuns":   { "folder": ".verbinal/exec",      "format": 1, "since": "2026-09-20T17:45:03Z" },
    "stagedScripts": { "folder": ".verbinal-scripts",   "format": 1, "since": "2026-08-02T11:00:00Z" },
    "exports":       { "folder": "Verbinal-Exports",    "format": 1, "since": "2026-09-01T08:15:40Z" }
  }
}
```

- `folder` is relative to the home. `format` is the kind's item format. `since` is when the kind was
  first declared (ISO 8601, UTC).
- **Keep what you do not know.** A Verbinal that meets a kind or a field it does not know writes it back
  as it was.
- **A newer format is left alone.** A Verbinal that meets a kind's `format` newer than it reads skips
  that kind and says so; it does not guess. A manifest `version` newer than it reads is not written.
- **Write from the latest.** Before writing the manifest, read it again, change only what you mean to,
  and write it whole.
- **The first manifest.** When there is none, a Verbinal writes one declaring the kinds whose folders
  already exist. It writes none when there are none: no folder is made for nothing. `research` is
  declared only when the person chooses to keep Research in VOSpace.
- **Private.** The manifest holds folder names and dates only: no observation names, no local paths,
  no tokens.

## The kinds

| Kind | Folder | Items | Written by |
|---|---|---|---|
| `research` | `.verbinal/research` | One JSON file per Research record (below) | Verbinal, when the person keeps Research in VOSpace |
| `workflows` | `.verbinal/workflows` | One record per working copy: its file name (`slug`) and its text | Verbinal, when the person keeps their workflows there |
| `savedQueries` | `.verbinal/queries` | One record per saved query | the same, for saved queries |
| `recentSearches` | `.verbinal/recent-searches` | One record per recent search, the last 100 | the same |
| `guides` | `.verbinal/guides` | One record per guide (`guide`), tool description (`toolDescription`) or the default session instructions (`sessionInstructions`) | the same; only what is in force, never a proposal |
| `computeHistory` | `.verbinal/compute-history` | One record per Remote Compute run: who, what, on which image, how it ended | the same |
| `jobHistory` | `.verbinal/jobs` | One record per finished batch job, with its reason | the same |
| `userImages` | `.verbinal/images` | One record per image added to the launch list | the same |
| `recentLaunches` | `.verbinal/launches` | One record per recent launch | the same |
| `portalDefaults` | `.verbinal/portal` | The account's launch defaults | the same |
| `imagePackages` | `.verbinal/manifests` | `<image id, sanitized>.json`: an image's installed packages | Image Discovery's probe jobs, running on CANFAR |
| `computeRuns` | `.verbinal/exec` (`inbox/`, `out/`) | A run's request in `inbox/`, its result in `out/` | Remote Compute: Verbinal writes the request, the CANFAR session the result |
| `stagedScripts` | `.verbinal-scripts` | `<sha>.py`: a batch job's script | A batch job launched with a `script` |
| `exports` | `Verbinal-Exports` | A zipped export bundle, or a search's results (`verbinal-results-<time>.csv`, `.tsv`, `.xml`) | **Upload to VOSpace** after an export; Search's **Export ▸ To Storage**; `export_search_results` with `uploadToVOSpace` |

## Syncing

1. List `.verbinal/` (one request). The manifest's size and date say whether it changed since this
   device last read it; read it only then.
2. For each declared kind this Verbinal knows, list its items folder (one request). An item whose size
   or date differs from what this device last saw is read; the others are not.
3. Never delete. Image package lists are imported into the device's cache when it has none for that
   image, or an older one. A result in `exec/out/` goes to its run. Scripts and exports are counted.

Verbinal for macOS syncs right after sign-in, in the background; again when it comes back to the front
and the last sync is over 15 minutes old; a few seconds after a collection the person keeps in VOSpace
changes; and with **Sync Now**. It waits longer between automatic syncs while VOSpace fails. An account
without a storage home (a CADC account without CANFAR) is synced not at all: nothing is read or written.

The person chooses each collection of their work (`research` to `portalDefaults`) in Settings ▸
Storage; Verbinal never declares one by itself. Every collection follows one rule — Research's, below:
one file per item named by the hash of its key, the newer change wins, a removal is a mark, fields a
later build wrote are kept, nothing while `.verbinal/` is readable by anyone. A record of a list is
`{ "format": 1, "key": …, "changedAt": …, "removedAt": …, "record": { the list's own record } }`.

## Research items

`.verbinal/research/<key>.json`, where `<key>` is the first 16 bytes, in hex, of the SHA-256 of the
record's key: its publisher ID, followed by `#` and the cutout's key for a cutout. The same record has
the same file on every device.

```json
{
  "format": 1,
  "recordKey": "ivo://cadc.nrc.ca/CFHT?1525350/1525350p",
  "changedAt": "2026-10-08T14:05:00Z",
  "details": {
    "publisherID": "ivo://cadc.nrc.ca/CFHT?1525350/1525350p",
    "collection": "CFHT", "observationID": "1525350", "targetName": "M31",
    "instrument": "MegaPrime", "filter": "r.MP9601",
    "ra": "10.684", "dec": "41.269", "startDate": "56245.3", "calLevel": "2",
    "previewURL": "https://…", "thumbnailURL": "https://…"
  },
  "note": { "text": "Seeing 0.6\"; usable for the mosaic.", "rating": 4, "tags": ["usable", "mosaic"] }
}
```

- An item carries the observation's details and the person's note. It never carries files, local paths,
  bookmarks, or who on which device made a change.
- **The newer change wins.** When both devices changed a record since they last agreed, `changedAt`
  decides; the device whose change lost keeps it locally, so the person can put it back.
- **Removal is a mark.** A record the person removes gets `"removedAt"` (and a new `changedAt`); other
  devices remove it on reading the mark, and keep its notes as Research does. A missing item means
  nothing: it removes nothing. A device marks only records it had itself.
- **Private only.** Research is written and read only while `.verbinal/` is not readable by anyone.
  Verbinal never changes sharing by itself; the person makes the folder private in Storage.
