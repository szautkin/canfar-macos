# Plan 50 — iPhone and iPad: the welcome

The person (2026-10-24): "I would like us to have welcome screen after user accepts the TOS; especially when
user does not have canfar account, we want them to know that they can benefit of using app for checking
fits, cube viewer". Then: "let's split plan for welcome pop up and the search fucntionality, I need to
think more about the search on ios". The search is plan 51, parked.

## What it is

One card, not a tour, as the Mac's welcome is. It comes once, right after the Terms are accepted, and
says what Verbinal does **without an account** before what an account adds.

```
┌──────────────────────────────────────────┐
│               (Verbinal icon)            │
│           Welcome to Verbinal            │
│   Look at astronomical data on your      │
│   iPhone — no account needed.            │
│                                          │
│ 🖼 View and verify FITS                   │
│    Zoom, sky coordinates, checksums;     │
│    share a picture or the file.          │
│ ⬚ Explore spectral cubes                  │
│    Channels, spectra, moment maps.       │
│ 📱 Your files, on this iPhone             │
│    Open from Files, Mail or AirDrop;     │
│    keep them, share them.                │
│ ✦ Try it now                              │
│    Two sample files: M31 from Hubble,    │
│    GN-z11 from Webb.                     │
│ ── With a CANFAR account ──              │
│ ▭ Portal and Compute                      │
│    Your sessions, your code, your        │
│    storage.                              │
│                                          │
│          [ Get Started ]                 │
│           Sign In to CANFAR              │
└──────────────────────────────────────────┘
```

- **When:** once, after the Terms are accepted, while the welcome version the person last saw is below
  the current one. It is the Mac's rule (`WelcomePreferences`), shared. Raising the version shows it to
  everyone again, after a release that changes what the app does.
- **Signed in** (a stored session): the same card, without Sign In.
- **Get Started** closes it. The person is on FITS (plan 49), whose empty page offers Open…, with the
  samples (D1).
- **Sign In to CANFAR** closes it, then opens the sign-in sheet. One sheet at a time: the same
  `onDismiss` step as the menu's (plan 49).
- **Again later:** Menu ▸ Help ▸ **Welcome**.
- **iPad:** the same card, as a form sheet.

**Why one card:** Apple's Human Interface Guidelines (onboarding) say to keep onboarding short and
skippable, to teach by doing rather than by pages, and not to ask for sign-in before the person sees the
value. The samples are the "doing".

## How it is built (Pragmatic principles, applied)

| Principle | Here |
|---|---|
| **DRY** | **One rule for when a welcome shows.** `WelcomePreferences` (the seen-version key, the current version) and the decision `shouldShow(seenVersion:, termsAccepted:, sheetUp:)` move out of the Mac-only `WelcomeSheet.swift` into a shared file. The Mac's `ContentView.maybeShowWelcome` and iOS use the same function; the cards differ. |
| **Orthogonality** | The card knows nothing of the places. Its two actions are closures the shell gives it (close; close then sign in). ContentView shows it through the existing `activeSheet = .welcome`: iOS now maps `.welcome` to `iOSWelcomeSheet`, not `EmptyView`. |
| **ETC** | **The rows are data** (`iOSWelcomeItem`): a symbol, a title, a line, and whether it needs an account. Plan 51's Search becomes one row, and the card's view does not change. The version number is the one knob for showing it again. |
| **Tracer bullet** | W0 is the whole path, thin: Terms → the card (title, rows, Get Started) → FITS. Then Sign In, the Help entry, polish. |
| **No broken windows** | The Mac's welcome keeps working unchanged; its tests run. |

## Steps

| # | Step | Size |
|---|---|---|
| **W0** | `WelcomePreferences` and `shouldShow` shared, with the Mac using them; `iOSWelcomeItem` rows; `iOSWelcomeSheet` with Get Started; iOS `ContentView` shows it after the Terms. | S |
| **W1** | Sign In to CANFAR (close, then the sign-in sheet); the signed-in variant; Menu ▸ Help ▸ Welcome (`iOSMenuEntry.welcome`). | S |
| **W2** | VoiceOver (the rows read as one each; the buttons labelled), Dynamic Type (the card scrolls at large sizes), French, iPad form sheet; tests; the Mac's tests for the shared rule. | S |

**Tests** (iOS unit tests, no host app):
- `shouldShow`: Terms not accepted, seen this version, an older version seen, another sheet up;
- the rows: signed out has the account section and Sign In, signed in has no Sign In, every row has its
  words.

The Mac's tests cover the shared rule there.

## Decisions

The person (2026-10-24): "let's do the welcome plan 50". Every decision is taken as recommended.

| # | Decision | Taken | Not taken |
|---|---|---|---|
| D1 | The main button | **Get Started**: close, onto FITS, whose Open… has the samples | **Try a Sample**: close and open M31 at once |
| D2 | Who sees it | **everyone, once per welcome version; signed in without Sign In** | only those signed out |
| D3 | The account section | **one row: Portal and Compute, with storage** | none: only what works without an account |
| D4 | Again later | **Menu ▸ Help ▸ Welcome** | not at all |

## As built (2026-10-24, branch `1_4_1_ios`, uncommitted)

W0 to W2 in one change.

- **The shared rule:** `Verbinal/Views/Sheets/WelcomePreferences.swift` (both apps) holds the version, the
  key and `shouldShow(seenVersion:termsAccepted:sheetUp:)`. It moved out of the Mac's `WelcomeSheet.swift`.
  `ContentView.maybeShowWelcome` uses it on both, at launch and when the Terms are accepted, with the same
  triggers as before. ContentView is down to 668 lines.
- **iOS:**
  - `.welcome` shows `iOSWelcomeSheet`: the icon, the title, the rows from `iOSWelcomeItem` (four
    without an account, then "With a CANFAR account"), and Get Started and Sign In to CANFAR pinned at
    the bottom (`safeAreaInset`).
  - The card scrolls at large text sizes and is at most 520 points wide on iPad. VoiceOver reads each
    row as one.
  - However it closes (a button or a swipe), it is stamped as seen.
  - **Sign In** stamps it and swaps the sheet in place (`activeSheet = .login`), the Mac's idiom.
  - Signed in, there is no Sign In.
- **Menu ▸ Help ▸ Welcome to Verbinal** (`iOSMenuEntry.welcome`). The shell's "sign in once the sheet has
  gone" became a general `nextSheet` (`presentNextSheet()`), used by Sign In and the welcome alike.
- **Seen on screen** (a throwaway UI tour on the test simulator, kept out of the repository):
  - the card after the Terms;
  - Sign In to CANFAR, which opens the sign-in sheet;
  - Help ▸ Welcome to Verbinal, which brings it back;
  - Get Started, which lands on FITS with Open….
- **Tests:** `WelcomeTests`, 3 tests (`shouldShow`'s cases; the rows' order and sections; every row has
  its words). The menu's tests now cover the Welcome entry. iOS: 54 tests pass. The Mac builds; its
  guardrail and presentation tests pass (17).
- **French:** 14 new keys. "Welcome to Verbinal" was already translated.

