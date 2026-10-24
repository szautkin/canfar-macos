# Plan 49 — iPhone and iPad without a CANFAR account

The person (2026-10-23), after plan 48: "we should enable fits and cube viewer for all users regardless of
their canfar account..., keep portal and compute disabled/gray out and a lock overlay on those icons but let
users able to view their fits and cube files share them manage files on the phone please"

## Where things are now

| What | Today |
|---|---|
| Signed out | The whole app is one screen: "Login Required", Login, About (`ContentView.loginRequiredView`). Nothing else can be reached. |
| Signed in | `AuthenticatedRootView` builds the Portal's models (sessions, launch, platform load, storage) and shows `iOSShell`: Portal · FITS · Cube · Compute. |
| Sign Out, or a session that expires | Back to "Login Required". The viewers' tabs survive in `AppState`, but the shell's state (the open file's page, the menu) goes. |
| "Open in Verbinal" from Mail or Files while signed out | Remembered (`pendingFITSURL`), and opened only after sign-in. |
| FITS, Cube, On This iPhone | They need no account. They read files on the device; only Your Storage and a storage file's page read CANFAR. |

## The design

### Everyone gets the app; the account adds to it

Signed out, the app opens on the same four places:

```
┌ FITS ─────────────────────────────── (👤) ┐        ┌ Portal ────────────────────────── (👤) ┐
│                                           │        │                                         │
│        No Image Open                      │        │              🔒                         │
│   The FITS images you open to review      │        │   Your CANFAR sessions                  │
│   appear here.                            │        │   Sign in to see and launch your        │
│        [ Open… ]                          │        │   sessions, the platform's load and     │
│                                           │        │   your storage.                         │
│                                           │        │   [ Sign In ]   About CANFAR ↗          │
├───────────────────────────────────────────┤        ├─────────────────────────────────────────┤
│ 🔒▭  Portal   🖼 FITS   ⬚ Cube   🔒>_ Compute │     │ 🔒▭  Portal   🖼 FITS   ⬚ Cube   🔒>_ Compute │
└───────────────────────────────────────────┘        └─────────────────────────────────────────┘
```

- **Open to everyone:** FITS, Cube and menu ▸ On This iPhone.
  - Open a file from the Files app, from Mail or AirDrop ("Open in Verbinal"), or one already on the
    device: Kept, Downloads, From Other Apps.
  - View it, verify it, and share it: a picture of the view, or the file itself.
  - Manage what is on the phone: delete, keep, clear, review.
- **Locked: Portal and Compute.**
  - Their icons are drawn grey, with a small lock at the corner.
  - A tap shows what the place is for and **Sign In** (D1).
  - Your Storage, Session Reminders and AI Compute in the menu are locked the same way.
- **Signed in:** everything is as today.
  - Signing out keeps the person in the app, on FITS. Only Portal and Compute lock again.
  - A session that expires locks Portal and Compute and asks for sign-in. FITS and Cube go on as they
    were.

**Why:**
- Apple's App Review Guidelines (5.1.1 v) say an app should let people use what does not depend on an
  account without signing in.
- The Human Interface Guidelines (Managing accounts) say to delay sign-in as long as possible.
- Viewing and verifying FITS files does not depend on CANFAR. A student, a reviewer, or a colleague who
  was sent a file can use it. The App Store reviewer can test the viewers without a demo account.

**Why grey and locked, but still tappable:** Apple's tab bar guidance is not to disable or hide a tab when
its content is unavailable, but to say why. So the lock is on the icon, as the person asked, and a tap
explains the place and offers Sign In. A tab that ignores a tap would read as broken (D1).

### Signed out, place by place

| Where | Signed out |
|---|---|
| Portal, Compute | the lock screen: what the place is for, Sign In, and canfar.net (D5) |
| FITS, Cube | as signed in |
| Open (sheet) | Recent: device files open; a storage file opens when this device has a copy, else it shows a lock and asks to sign in. Your Storage ▸ a locked row with Sign In. Files… as today. |
| A storage file's page | its copy here opens; with none, "Sign in to read it from your storage" and Sign In |
| Menu | at the top, "Not signed in" and **Sign In**. Files: On This iPhone ✓, Your Storage 🔒. Settings: Downloads Kept Up To ✓, Session Reminders 🔒, AI Compute 🔒. Help ✓. **Sign In** where Sign Out was. |
| On This iPhone | everything; Show in Storage is left out |
| While the sign-in is being checked (a stored session) | Portal and Compute say "Checking your sign-in…", so no lock flashes. FITS and Cube are already usable. |
| Offline, with a stored session | Portal and Compute say Verbinal is waiting for the network, with Try Again (today's message, moved there) |

- **Where the app opens:** on Portal with a stored session (as today); on FITS without one (D2).
- **After sign-in:** the place the person asked from (the Portal lock screen, the menu, Open), not
  always Portal.
- **Sign Out:** it asks what to do with what came from the account (D3):
  - **Sign Out** keeps the files on this iPhone;
  - **Sign Out and Delete Downloads** also removes the storage copies in Downloads.

  Kept files stay either way: the person chose to keep them. Session reminders are cancelled.
- **Share** in FITS and Cube becomes a menu: **Picture of the View** (today's) or **The File**, so a file
  can go to a colleague as it is.
- **The first run:** two small public sample files, an image and a cube, from Open ▸ Samples (D4). Then
  someone with no FITS file at hand, App Review included, can try the viewers.

## How it is built (Pragmatic principles, applied)

| Principle | Here |
|---|---|
| **Orthogonality** | Places do not check the sign-in themselves. One function, `iOSPlaceAccess`, says what a place may show: open, checking, waiting for the network, or locked. One view, `iOSLockedPlace`, shows a locked place. FITS, Cube and Files know nothing of accounts; Portal and Compute are shown only when open. |
| **DRY** | Each place says once whether it needs an account (`iOSDashboardTab.needsAccount`), and so does each menu entry (`iOSMenuEntry.needsAccount`). The lock icon is made in one place for the tab bar and the sidebar. The Portal's models are built by **one** factory, `DashboardModels`, that the Mac's `AuthenticatedRootView` and the iOS shell both call, instead of the wiring living in a view. |
| **SOLID** | **S:** the gate decides, the views show, the factory builds. **O:** a new locked place is `needsAccount: true`, with no view changed. **L/I:** Portal and Compute take the account's models as they do now; they only appear when there are some. **D:** the shell is given `DashboardModels?`: nil signed out, built on sign-in, dropped on sign-out. |
| **ETC** | Each locked place's words are in one table, and the starting place is one rule. The menu's layout stays data, now with `signedIn`. |
| **Tracer bullet** | L0 goes end to end thin: the shell for everyone, Portal and Compute locked, sign in and out without leaving the app. Then the details. |
| **No broken windows** | The "Open in Verbinal" file that waits for a sign-in today opens at once. A session that expires no longer throws away the open file's page. |

**Keeping to what is there:**
- `AppState.swift` is at its size ceiling (793). The starting place and the place to return to after
  sign-in live in an iOS extension, not in `AppState` itself.
- The sign-in itself (`LoginSheet`, `appState.showLoginSheet`, the keychain, `isCheckingSignIn`,
  `authAwaitingConnectivity`) does not change.
- The Mac does not change in behaviour: `AuthenticatedRootView` calls the same factory; the Mac's tests
  check it.

## Steps

| # | Step | Size |
|---|---|---|
| **L0** | Tracer bullet. iOS shows `iOSShell` signed in or out (ContentView's iOS landing). `DashboardModels` is extracted from `AuthenticatedRootView`, built on sign-in and dropped on sign-out. `iOSPlaceAccess` and `iOSLockedPlace`: Portal and Compute locked, with a grey icon, a lock, and Sign In. FITS, Cube and On This iPhone work signed out. Sign Out stays in the app, on FITS. | M |
| **L1** | Signed out wherever it shows: the menu (Not signed in, Sign In, locked entries); Open (storage locked, Recent storage files); a storage file's page; Show in Storage hidden. The checking and offline states in the locked places. A session that expires locks Portal and Compute only. The starting place, and the place after sign-in. | M |
| **L2** | Share ▸ Picture of the View / The File. Sign Out's choice (D3) and the reminders cancelled. Samples (D4). The canfar.net link (D5). VoiceOver ("Portal, locked: sign in to use it"); French; iPad's sidebar; tests; App Review notes ("FITS and Cube need no account; Portal and Compute need a CADC account, demo credentials attached"). | S–M |

**Tests** (iOS unit tests, no host app):
- `iOSPlaceAccess`: each place against signed in, signed out, checking, and offline with a stored session;
- `needsAccount`: Portal and Compute need an account, FITS and Cube do not;
- the menu's layout signed in and out: locked entries, Sign In instead of Sign Out;
- the starting place;
- Sign Out's choice: which kinds go.

The Mac tests check that `DashboardModels` wires the Portal as before.

## Decisions

The person (2026-10-23): "request account nope, just to canfar.net page link; proceed". D5 as they said;
the rest as recommended.

| # | Decision | Taken | Not taken |
|---|---|---|---|
| D1 | Portal and Compute signed out | **grey icon with a lock, and a tap shows what the place is and Sign In** (Apple: say why, don't disable a tab) | the tap does nothing, or only opens the sign-in sheet |
| D2 | Where the app opens without a stored session | **FITS** | Portal's lock screen |
| D3 | Sign Out and the files from the account | **ask: keep them, or delete Downloads** (Kept stays) | keep everything silently; always delete Downloads |
| D4 | Samples for the first run | **two small public files bundled (an image and a cube, under 2 MB together, with their credit)** | none; downloaded on demand from the CADC archive |
| D5 | A link on the lock screens | **canfar.net**, the platform's page (the person) | a "Request an account" link to CADC's request page |
| D6 | Order | **now** ("proceed") | after the Simulator check of plan 48 |

## As built (2026-10-24, branch `1_4_1_ios`, committed as de162466)

L0 to L2 are built, the samples (D4) included.

- **For everyone:**
  - ContentView's iOS landing is `iOSShell()`, signed in or out. "Login Required" and the full-screen
    sign-in check (`iOSSignInCheckView`) are gone from iOS.
  - The shell owns `account: DashboardModels?`: built and loaded when `isAuthenticated` turns true
    (`.task(id:)`), dropped when it turns false, whether by Sign Out or by an expired session (the
    renewal clears it before asking to sign in again).
- **One factory:** `Verbinal/ViewModels/DashboardModels.swift` holds the Portal's wiring (session counters,
  limits, headless model, platform load, storage), moved out of `AuthenticatedRootView`. On the Mac,
  `AuthenticatedRootView` builds it and shows `DashboardView` as before; on iOS it is the shell.
- **The gate:**
  - `iOSPlaceAccess.of(needsAccount:signedIn:checking:waitingForNetwork:)` answers open, checking,
    waiting for the network, or locked.
  - `iOSDashboardTab.needsAccount` is true for Portal and Compute.
  - `iOSLockedPlace` shows the locked states:
    - "Checking your sign-in…";
    - "Waiting for the Network", with the status line and Try Again;
    - locked: the place's purpose, **Sign In**, and **About CANFAR** (canfar.net, D5).
- **Locked icons:** `iOSLockedSymbol` draws the place's symbol in grey with a small lock at its lower
  corner and a clear ring round the lock. It uses original rendering, so it stays grey when selected, and
  serves the tab bar and the sidebar. The sidebar row is secondary. VoiceOver reads "Portal, Locked: sign
  in to use it", through the tab title's own `accessibilityLabel`, since a tab item takes a plain label.
- **Where the app opens:** decided once, when the sign-in check answers. A locked place gives way to FITS
  (D2). With a stored session waiting for the network, Portal stays and says so.
- **The menu, signed out:**
  - Sign In comes first, as Settings puts "Sign in to your iPhone", with a footer: what the account adds,
    and that FITS, Cube and the files need none.
  - Your Storage, Session Reminders and AI Compute show grey with a lock; a tap asks to sign in.
  - The initials become a person symbol.
  - `iOSMenuEntry.layout(signedIn:)` and `needsAccount` hold all of this as data.
- **Sign In from a sheet** (the menu, Open): the sheet closes, then the sign-in sheet opens (`onDismiss`).
  Two sheets cannot be up from two places at once.
- **Open, signed out:**
  - A Recent storage file that this device has opens. One it has not shows a lock and asks to sign in.
    `DeviceFiles.has(_:)` answers that without counting the file as opened.
  - Your Storage is a Sign In row.
- **A storage file's page, signed out, with no copy here:** "This file is in your storage. Sign in to read
  it." and Sign In. Its headers are read once the person is signed in.
- **On This iPhone:** everything works; Show in Storage is left out signed out.
- **Share:** FITS and Cube have a Share menu: **Picture of the View** or **The File**. One type,
  `iOSFileShare`, shares a file from the viewers, a file's page and On This iPhone. Verbinal's own files
  go as they are; a file opened in place from the Files app is copied while Verbinal may read it.
- **Sign Out (D3):** it asks: **Sign Out**, or, when there are any, **Sign Out and Delete Downloads (size)**.
  Kept files stay. The app moves to FITS if it was on Portal or Compute. With the sessions gone, the
  reminders are rescheduled to none: cancelled.
- **After sign-in:** the shell stays where it was, so the person is on the place they asked from. Nothing
  needed building for it.
- **D4, samples:**
  - **Where they came from.** CADC's query services were down that evening. The person then said: "we
    can use those images from vospace -> modify but put some attribution there
    showcase-cubes-2026-10".
  - **How they were fetched.** Through Verbinal's own tools, as the person's session instructions asked
    ("Use only Verbinal and its tools for this work: no other apps, and no network connections outside
    Verbinal"). Two files were downloaded to their Mac's Downloads folder; the cutting down was local.
  - **The two files**, in `Verbinal/iOS/Samples/`, 1.66 MB together. Each is a single HDU whose header
    credits the observation (COMMENT), says what was done (HISTORY), and carries a correct
    DATASUM/CHECKSUM, so Verify shows it whole.

    | File | From | Cut down |
    |---|---|---|
    | `M31-Hubble-WFPC-1991.fits` | `w0q2040at_c0f.fits`: NASA/ESA HST, WF/PC, F702W, proposal 2735, 1991-09-10, M31 (before the 1993 optics fix) | chip 4 (WF4), averaged 2 × 2 to 400 × 400; its WCS from the GEIS group table, scaled |
    | `GN-z11-JWST-NIRSpec.fits` | `GNz11_HeII_Hgamma_subcube.fits`, from `jw04528-o001_t001_nirspec_g395h-f290lp_s3d.fits`: NASA/ESA/CSA JWST, NIRSpec IFU G395H, program 4528 (PI Kate Isaak), 2025-04-09 | SCI only; channels 167–246 (5.011–5.064 µm, around Hγ at z = 10.6); the whole 57 × 55 field; CRPIX3 moved, CRVAL1 written as 189.106° (the file had −170.894°) |

  - **In the app.** Open ▸ **Samples** lists them, with their credit lines (`iOSSample`). They open from
    the bundle, signed in or not, and stay out of Recent.
  - **Tests:** `SamplesTests`, 2 tests:
    - each listed sample is in the folder, intact by Verbinal's own Verify, and credited;
    - together they are under 2 MB;
    - the image opens in FITS and the cube in Cube.
- **App Review notes (plan 47, phase 7):** FITS, Cube and the files need no account; Portal and Compute
  are locked until sign-in.
- **Tests:**
  - `PlaceAccessTests`, 3 tests (the gate's table);
  - `FilesRulesTests`, +2 (the menu signed in and out, what needs the account);
  - `DeviceFilesTests`, +1 (`has` does not count as opened);
  - `SamplesTests`, 2.

  The iOS bundle: 51 tests, passing.
- **French:** 23 new keys; 2 keys only the removed code used are gone.
- **Seen on screen (2026-10-24).** The person allowed it once: Claude ran a throwaway UI test, kept out
  of the repository, on a test iPhone simulator with no stored session.
  - **As built:**
    - signed out, the app opens on FITS;
    - Portal and Compute show grey icons with a lock;
    - Portal's lock screen has its words, Sign In and About CANFAR;
    - the menu has Sign In first and its locked entries;
    - Open ▸ Samples lists both files, with their credit;
    - M31 opens in FITS, with its compass and a 15″ scale bar (its WCS reads);
    - GN-z11 opens in Cube at 5.0376 µm, with the line in the mean spectrum;
    - Share ▸ The File opens the share sheet with the file.
  - **Fixed from what was seen:**
    - **The viewers' bar.** With a long file name, iOS folded Share, Adjust and ✕ Close into its "•••"
      overflow, so the person's "no close" would have come back. The title is now drawn by the viewer
      (`iOSViewerTitle`, the file name's menu): it truncates in the middle, at the width the menu button
      and the three buttons leave. Fewer buttons alone did not help.
    - **Locked menu rows** were drawn in the tint's light blue (`.secondary` inside a button). They now
      use the grey colour, and so do Open's lock and the samples' credit lines.
  - **Signed in, then Sign Out (2026-10-24).** The person signed in on their own iPhone 17 simulator, and
    the tour went on there:
    - signed in: Portal and Compute open, and the menu shows the profile, Your Storage at 80 % and the
      settings unlocked, with Sign Out last;
    - Sign Out asks: plain **Sign Out**, or **Sign Out and Delete Downloads (10.3 MB)**. The tour took the
      plain one, so the downloads stayed.
    - After it: the app is on FITS, the menu button is a person symbol, and Portal and Compute are locked
      again.
  - **An expired session: checked in the code, and the launch case on screen.** On screen (2026-10-24):
    a temporary, uncommitted debug hook stored a bogus token with no password on the test simulator.
    At launch the app asked at once ("Log In to CANFAR · Your CADC session ended. Sign in to continue."),
    and after Cancel Portal and Compute were locked, with FITS and Cube open. The hook and the tour target
    were removed afterwards. Mid-session expiry was not seen: it takes the same `settle(.ended)` path.
    The person
    (2026-10-24): "i was seeing in the macos version that the expiration does not automatically prompts
    user to login again... check the code logic instead thoroughly".
    - **The path, read end to end:**
      1. Every authenticated request goes through `NetworkClient`. A 401 calls
         `AuthLifecycleController.handleNetworkUnauthorized`, and one shared renewal runs.
      2. The renewal checks the token at `/whoami`, which counts an empty answer, a 401 or a 403 as
         expired.
      3. With a stored password it signs in again quietly. Without one it clears the token and ends.
      4. `settle(.ended)` sets the reason and calls `onSessionExpired`: AppState tears the session
         down, leaves the gated screens, and shows the sign-in sheet.
      5. On iOS the shell then drops the account's models and locks Portal and Compute. FITS and Cube
         stay.

      The archive search, CAOM-2, Research downloads and cutouts send their own requests, but
      anonymously: they carry no token, so they play no part.
    - **Three gaps, fixed (`AuthLifecycleController`), each with a test that fails without its fix:**
      1. **At launch, an ended session never asked.** A stored token found expired, with no stored
         password, ended the session quietly: the sheet was asked only when this run had been signed in
         (`wasAuthenticated`). The likely Mac report: the token expired while Verbinal was closed or
         the Mac slept, and the next launch said "Session expired" in the toolbar and nothing more. Now
         a renewal that starts from an expired stored token (`.expiredToken`, at launch or when the
         network returns) counts as the person's session, and asks.
         (`testAStoredSignInThatEndedAtLaunchAsksToSignIn`; with no stored sign-in, nothing:
         `testNoStoredSignInAtLaunchAsksNothing`.)
      2. **What a renewal's sign-in started never asked for a renewal again.** `apply` called
         `onAuthenticated` inside the renewal, where `Renewing.now` is true. `afterAuthenticated`
         starts its watchers in `Task {}` (Remote Compute; on the Mac, Research repair and the storage
         sync), and unstructured tasks inherit task-locals. So after a launch that renewed with the
         stored password, their 401s skipped the renewal for the rest of the run. Now the hook runs
         with `Renewing.now` false. (`testWhatASignInStartsStillAsksForRenewals`.)
      3. **Nothing looked until a request failed.** A session that ended while Verbinal sat in the
         background showed nothing until something authenticated failed. Now ContentView, through
         `scenePhase` (the Mac and iOS alike), calls `AppState.appDidBecomeActive` →
         `recheckIfStale()`. A sign-in CADC has not confirmed for 15 minutes is checked again, and one
         that ended asks at once. (`testComingBackAfterAWhileChecksTheSignIn`,
         `testComingBackWithASignInStillGoodChangesNothing`.)
    - **A risk left, not changed:** the sign-in sheet is `activeSheet`, ContentView's single sheet. If
      another sheet is up when a session ends (a Portal sheet on the Mac, the menu on iOS), SwiftUI
      may not show it. `activeSheet` then stays `.login`, so a later end would not show it either.
      Check that on screen when a session next ends.

