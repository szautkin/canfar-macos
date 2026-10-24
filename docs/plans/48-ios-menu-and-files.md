# Plan 48 — iPhone and iPad: the menu, and the files

The person (2026-10-23), after Phase 5 of plan 47: "I think we need to add a menu button that should also have
a File manager (delete files from the phone memory?...maybe, vo space storage as well, but keep those 4 items in
the bottom I like it it is clear and simple Portal FITS Cube Compute; plan this functionality considering best
apple ios practice; do not forget we still following Progmatic Programmer principles like ETC SOLID DRY
Orthogonality etc..."

## Where things are now

| What | Where | Today |
|---|---|---|
| Account | the initials button, top left of every place | a sheet: profile, reminders, AI Compute, About, Terms, Sign Out |
| Downloads from storage | `Caches/Verbinal/Remote` (`RemoteFileCache`), capped at 2 GB, LRU | no list, no delete: only the cap trims them |
| Files sent by other apps ("Open in Verbinal") | from Files: read in place (a bookmark); from Mail or AirDrop: a copy in `Documents/Inbox` | the Inbox copies stay forever |
| Recents | `iOSRecentFiles`, 20, on the device | Remove (swipe) in Open |
| Your storage | `iOSStorageFolderView`, inside Open | browse and pick only |

The storage client (`VOSpaceBrowserService`) can already list, download, upload, create folders and delete
(`deleteNode`, recursive).

## The design

### One menu, the four places untouched

The tab bar keeps **Portal · FITS · Cube · Compute**. Everything else is behind **one button, in the same place
on every screen** — the initials button that is there now — and it becomes the app's menu.

**Why this and not a hamburger menu or a fifth tab:**
- Apple's guidance is to keep the tab bar for the app's top-level places, and not to hide navigation in a
  side drawer.
- A fifth tab would make Files look like a place to work in, which it is not. It is housekeeping.
- Apple's own apps put account, settings and their extras behind the profile button, in a sheet (App Store,
  Music, Podcasts). People know where to look.

```
┌ Portal ───────────────────────────── (SZ) ┐     tap (SZ)
                                                ┌──────────────────────────────────────┐
                                                │ Serhii Zautkin            ✓ Done     │
                                                │ szautkin · CADC                      │
                                                ├ Files ───────────────────────────────┤
                                                │ 📱 On This iPhone          1.3 GB  › │
                                                │ ☁︎ Your Storage    82 % of 2 TB    › │
                                                ├ Settings ────────────────────────────┤
                                                │ Session Reminders              [on]  │
                                                │ Downloads Kept Up To        2 GB  ›  │
                                                │ AI Compute                         › │
                                                ├ Help ────────────────────────────────┤
                                                │ Verbinal Help (docs.verbinal.com)  › │
                                                │ About Verbinal · Terms of Use        │
                                                ├──────────────────────────────────────┤
                                                │ Sign Out                             │
                                                └──────────────────────────────────────┘
```

On iPad it is the same sheet (a form sheet); the sidebar keeps the four places. Signed out, the button shows a
person symbol, and the menu still has the files on the device, Settings and Help.

### On This iPhone (or iPad)

The files Verbinal holds on the device, as **iPhone Storage** in Settings shows an app's (General ▸ iPhone
Storage): what there is, its size, and what can go.

```
┌ On This iPhone ────────────────────────── Edit ┐
│ Verbinal uses 1.3 GB                            │
│ ▇▇▇▇▇▇▇▇▇▇░░░░  Downloads 1.1 GB · Kept 180 MB │
│ [Clear Downloads…]                              │
│ Not opened in 30 days: 3 files, 640 MB  [Review]│
├ Kept ───────────────────────────────────────────┤
│ 🔒 ngc2403_hi.fits     180 MB · opened today  › │
├ Downloads (the cache) ──────────────────────────┤
│ m31_r.fits             64 MB · from out/      › │
│ reduced_cube.fits     1.0 GB · 3 weeks ago    › │
├ Received from Other Apps ───────────────────────┤
│ test_image.fits        8 MB · from Mail       › │
└─────────────────────────────────────────────────┘
```

- **Three kinds, each saying what deleting it means:**

  | Kind | Where | Deleting it |
  |---|---|---|
  | **Downloads** (the cache) | `Caches/Verbinal/Remote` | removes this device's copy; the file stays in storage |
  | **Kept** (the person asked to keep it offline) | `Documents/Kept`, visible in the Files app, excluded from iCloud backup | removes it from this device (it can be downloaded again) |
  | **Received** (from Mail, AirDrop) | `Documents/Inbox` | removes Verbinal's copy; the sender's stays |

  Files opened in place from the Files app are not Verbinal's to delete. They appear only under Recent, where
  **Remove from Recent** forgets them; deleting them belongs to the Files app.
- **A file's row:** name, size, where it came from, when it was last opened.
  - A tap opens it (in FITS or Cube, through the shell's routing).
  - **Swipe:** Delete. A swipe is itself the confirmation, as in Apple's lists; there is no second question
    for a single file.
  - **Its menu:** Open, Share, Keep on This Device (Downloads, Received) or Don't Keep (Kept), Show in
    Storage, Delete.
- **Edit:** several at once, then **Delete** with one confirmation that names how many files and how much
  space.
- **Clear Downloads…:** confirmed, and leaves Kept and Received alone.
- **Downloads Kept Up To** (menu ▸ Settings): 1, 2, 5 or 10 GB, for the cache's cap.
- **Not opened in 30 days:** a suggestion with Review, as iPhone Storage makes them. Nothing is deleted
  without the person.
- **An open file deleted:** its viewer tab is closed first, so no viewer is left reading a gone file.
- **Searchable;** sorted by size, date or name.

### Your Storage

The person's CANFAR storage, managed, not only browsed: the same folder list Open uses, with management
actions.

- At the top, the quota (the Portal ring's numbers).
- A file's menu: Open, Download, Keep on This Device, Share Link? (D4), Delete…; a folder's: Open, New Folder,
  Delete….
- **Delete…** always asks.
  - It names the file or folder.
  - For a folder, it says how many items it holds and that they all go.
  - It says the deletion cannot be undone: storage has no trash.
  - It is a `.confirmationDialog` with a destructive button, as the Portal's session Delete is.
- **New Folder;** **Upload from This Device…** (`.fileImporter`; D3).
- Pull to refresh; folders first, then newest first; FITS only, or all, as in Open.

## How it is built (Pragmatic principles, applied)

| Principle | Here |
|---|---|
| **Orthogonality** | Files is its own module, `Verbinal/iOS/Files/` (models, services, views). It does not know about viewers. To open a file it calls the shell's open action (`iOSOpenFile`, `iOSViewImage`, `iOSViewCube`). To close a viewer before a delete it calls one small `OpenFiles` protocol the shell implements. Viewers know nothing of Files. |
| **DRY** (of knowledge, not only code) | **One** `DeviceLibrary` knows where Verbinal's files are and what each kind means. `RemoteFileCache` becomes its cache policy (cap, LRU), not a second store; `FileInspection` asks the library, not the cache. **One** storage folder list, `iOSStorageFolderView`, serves Open (pick) and Your Storage (manage), and only its row actions differ. **One** destructive-confirmation text per kind. |
| **SOLID** | **S:** the library lists and removes, the cache policy trims, the storage manager deletes remotely; three types. **O:** a file's place is a `LocalFileKind` (cache, kept, received); a new kind adds a case and its rules, and no view changes. **I:** views depend on small protocols (`LocalFileListing`, `LocalFileRemoving`, `RemoteNodeRemoving`), not on concrete services. **D:** those are injected from the shell, so tests use fakes and a temporary directory. |
| **ETC** (easy to change) | The cap, the 30-day suggestion and the folder names are constants in one place. The menu's sections are data (a list of entries), so adding one is one line. The same views serve iPhone and iPad. |
| **Tracer bullet** | F0 goes end to end thin: the menu, then Downloads listed and deleted, before anything else is built out. |
| **No broken windows** | The Inbox copies that never go away today are part of F1, not "later". |

**Apple's file system rules, kept** (Apple's file system guide and its iCloud backup guidance):
- **Caches:** what can be downloaded again. iOS may purge it, so Verbinal never relies on it.
- **Documents:** what the person chose to keep. It is visible in the Files app because the app shares its
  folder (`UIFileSharingEnabled`), and Kept files are marked `isExcludedFromBackup`, since storage holds the
  original.
- **Documents/Inbox:** the system's. Verbinal reads it and deletes from it, and never writes to it.

**Privacy manifest:**
- Showing the device's free space (`volumeAvailableCapacityForImportantUsage`) is a required-reason API:
  `NSPrivacyAccessedAPICategoryDiskSpace`, reason **85F4.1** (shown to the person). It is added to
  `Verbinal/iOS/PrivacyInfo.xcprivacy` with the code, not after it.
- File sizes and dates are already declared (C617.1, 3B52.1).

## Steps

| # | Step | Size |
|---|---|---|
| **F0** | Tracer bullet: the initials button opens **the menu** (today's Account sheet, restructured: Files, Settings, Help, Account). **On This iPhone** lists the cache's files with size and date, swipe to delete, and a total. `DeviceLibrary` over `RemoteFileCache`. | S |
| **F1** | The three kinds (Downloads, Kept, Received). Keep on This Device and Don't Keep (a move by the person's tap, never automatic). Inbox copies listed and deletable. Edit and delete several; Clear Downloads; open, share; close a viewer before deleting its file; search and sort; the cap setting; the 30-day suggestion; Remove from Recent for files in place. | M |
| **F2** | **Your Storage:** the shared folder list with manage actions; quota; Delete… for files and folders (counts, cannot be undone); New Folder; Download, and Keep. | M |
| **F3** | Upload from This Device (D3); Help links; VoiceOver labels and hints; French; layout on iPad; tests. | S |

**Tests** (iOS unit tests, no host app): `DeviceLibrary` in a temporary directory (listing by kind, delete, keep
and un-keep, the backup flag set, the cap trimming only Downloads, Inbox read and delete); the confirmation texts
(counts, sizes, "stays in your storage"); the 30-day rule; the menu's sections as data.

## Decisions

The person (2026-10-23) set the goal "complete the plan" without choosing, so every decision is taken as
recommended.

| # | Decision | Taken | Not taken |
|---|---|---|---|
| D1 | The menu's button | **the initials button that is there now** (Apple's profile pattern), a person symbol when signed out | a menu symbol (`ellipsis.circle`) beside it |
| D2 | Where Kept files go | **`Documents/Kept`**: seen in the Files app, excluded from iCloud backup | Application Support (hidden) |
| D3 | Storage actions on iOS | **browse, download, keep, delete, new folder**; upload from the device in F3 | browse and delete only |
| D4 | Share a storage file as a link | **later** (it needs the ACL tools and a public-link decision) | in F2 |
| D5 | The cache's cap | **2 GB, the person's choice of 1, 2, 5 or 10 GB** | fixed |
| D6 | Order | **now** (the person's goal); plan 47's open items (the device sign-in check, the render speed) stay open beside it | after plan 47's open items |

## As built (2026-10-23, branch `1_4_1_ios`, uncommitted)

All four steps, F0 to F3, in one change; the decisions as taken above.

- **The module:** `Verbinal/iOS/Files/`:

  | Layer | Files |
  |---|---|
  | Models | `LocalFile.swift` (`LocalFileKind`, `FileOrigin`, `LocalFile`), `FilesRules.swift` (cap choices, the 30-day rule, folder names), `FilesWording.swift` (every confirmation's text) |
  | Services | `DeviceFiles` (where each kind lives; list, delete, keep, don't keep, local copy), `RemoteFileCache` (moved from Open: the cap and least-recent order), `FileOriginAttribute` (the origin on the file), `DeviceLibrary` (observable, for the views), `StorageActions` (Your Storage's calls) |
  | Views | `iOSDeviceFilesView` (with its row and usage bar), `iOSStorageFolderView` (moved from Open: pick or manage) and `iOSYourStorageView` |

  The menu itself is the shell's: `iOS/Shell/iOSMenuSheet.swift` (was `iOSAccountSheet.swift`) and
  `iOSMenuEntry.swift`, its sections as data.
- **Where a file came from** is kept on the file, as an extended attribute (`com.codebg.verbinal.origin`:
  storage path, size, date, when last opened). It moves with the file between kinds, leaves no extra
  file in the Files app, and goes when the file goes. Only Verbinal's own files carry one:
  `noteOpened` writes nothing on the person's files elsewhere, nor in the system's Inbox.
- **One answer to "is it here?":** `DeviceFiles.localCopy(of:)`, the kept copy of that version, else the
  cache's. `FileInspection` asks it, and its download is `StorageActions.download`, the same one Your
  Storage uses. Opening a file from On This iPhone goes through the shell's open, so a storage file shows
  its page and its copy as one.
- **F0:** the initials button opens the menu (Files, Settings, Help, Sign Out; profile at the top). On
  This iPhone (On This iPad) lists the files, their sizes, a total and a usage bar.
- **F1:**
  - Three kinds, each with a footer saying what deleting one means: Kept, Downloads, From Other Apps.
  - A file's row: name, size, "from out/", "opened 3 days ago" (or "added", for a file never opened
    here). Tap opens it, swipe deletes it, and its menu has Open, Share, Keep on This Device or Don't
    Keep, Show in Storage, and Delete….
  - Keep moves a file to `Documents/Kept` and marks it `isExcludedFromBackup`; Don't Keep gives a storage
    file back to the cache. A file that is not in storage cannot go back: it could not be downloaded
    again.
  - Edit, then Delete (n), with one question that names the count and the size and says whether storage
    still has them. Clear Downloads… asks, and leaves Kept and From Other Apps alone.
  - Search; sort by last opened, size or name.
  - Not opened in 30 days: a row that opens the same list showing only those files, with Delete All….
    Kept files are never suggested.
  - Downloads Kept Up To (menu ▸ Settings): 1, 2, 5 or 10 GB. A lower cap trims at once.
  - Before files go, the shell closes the FITS and Cube tabs showing them. A file's page that had one
    forgets it, or closes if the file was only on the device, and a device file leaves Recent.
  - Remove from Recent for files opened in place was already in Open (a swipe).
- **F2:** menu ▸ Your Storage is the folder list Open uses, with actions:
  - the quota gauge at the top of Home;
  - a file's menu: Open, Download, Keep on This Device, Delete…; a folder's: Delete…;
  - **Delete…** always asks. It names the item, counts a folder's items (one listing; "500 items or more"
    at the listing's limit), and says that storage has no trash. The swipe uses no destructive role,
    which would slide the row away before the answer.
  - New Folder (the name checked: no slash, not dots);
  - a badge on a file this device has, and download progress on its row;
  - after a deletion in storage, the copies on the device lose their storage path, so deleting them later
    says they cannot be downloaded again.
- **F3:**
  - Upload from This Device… (`.fileImporter`). A name already in the folder asks to Replace.
  - Help: Verbinal Help opens docs.verbinal.com.
  - VoiceOver: the menu button is "Menu", with a hint; rows read as one; the usage bar is hidden behind
    its legend; badges have labels.
  - iPad: the same sheet, as a form sheet.
- **Privacy manifest:** `NSPrivacyAccessedAPICategoryDiskSpace`, reason 85F4.1, for the free space shown
  under the usage bar; the FileTimestamp sources updated.
- **Not as planned:**
  - **Protocols.** The plan named small protocols (`LocalFileListing`, `LocalFileRemoving`,
    `RemoteNodeRemoving`, `OpenFiles`). As built, the seams are:
    - `DeviceFiles`, a value given its folders, which the tests use in a temporary directory;
    - the shell's close action, a closure as the app's other environment actions are.

    Your Storage calls `VOSpaceBrowserService` directly, and only its wording is tested.
  - **A signed-out menu:** the iOS shell is shown only when signed in, so there is none.
  - **Keep and Don't Keep** move a file without closing its viewer: the open copy keeps reading, and the
    tab keeps the old path.
  - **A cap lowered** trims without closing viewers. The least recently opened go first, so an open file
    is the last to go.
- **Tests:** `DeviceFilesTests`, 10 tests (each kind listed; keep moves out of the cache and out of
  backup; don't keep; a file not in storage cannot go back; the cap trims Downloads alone; delete; a
  deletion in storage forgotten; opening writes only on Verbinal's files; kept names numbered; an origin
  round trip). `FilesRulesTests`, 7 tests (the 30-day rule, the cap setting, folder names, the
  confirmation texts, the menu as data). The iOS bundle: 43 tests, passing. **French:** 60 new keys; 5
  keys only the Account sheet used were removed.
- **Builds:** VerbinalIOS Debug (Simulator) and Release (device) build. Nothing seen on screen yet: the
  person tries it in the Simulator.

