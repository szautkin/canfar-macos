# Dev plan — Auth scope: don’t block the whole app

**Status:** review complete · not started  
**Surface:** macOS ContentView / Landing / session-expiry  
**Related:** [Global plan](./00-global.md)

## Findings

### Intended design (already correct)

Auth is **not** meant to gate the whole app. Only:

| Surface | Auth |
|---------|------|
| **Portal** | Required |
| **Storage** | Required |
| Search, Research, FITS, Cube, Workflows, AI Guide, FileBrowser, Settings | Open without login |

This matches Windows (`RequiresAuth` only on Portal + Storage) and the landing tiles (`locked` only on those two). Menu ⌘5 / ⌘6 already open the **login sheet** without navigating when signed out.

### Why it *feels* like a global block

The screenshot (“Login Required” / “Sign in to continue.” / Back + Login filling the window) is `loginRequiredView` in `ContentView.swift` for **Portal or Storage while signed out**.

When that screen is shown, `showsModeChrome` is **false** — so there is **no toolbar, no landing tiles, no other modules**. The window is only the lock prompt. That happens when:

1. User was in Portal/Storage and the **session expired** / **logout** flipped `isAuthenticated` to false **without** leaving the mode, or  
2. Something left `currentMode` on `.portal` / `.storage` while signed out.

So the product rule is already “Portal + Storage only,” but the **signed-out Portal/Storage body** is a full-window dead-end that looks like an app-wide wall.

### What does *not* need a module gate

- **Search TAP** — public, no Bearer  
- **Research / FITS / Cube / Workflows (local)** — local or public archive paths  
- Proprietary CAOM2 / downloads may still need a token for *some* rows — handle with **inline** prompts, not a module lock (Windows ObsDetail pattern). Separate hardening: Mac CAOM2/download often omit Bearer today.

---

## Goals

1. Signed-out users always keep access to Landing + free modules.  
2. Portal/Storage never present a chrome-less full-window wall that feels global.  
3. Session expiry / logout bounce out of Portal/Storage (or keep chrome + path home).  
4. Keep Windows parity: only Portal + Storage require auth to enter.

---

## Approach

### Phase A — Session expiry / logout UX (P0)

1. On `logout` and on auth-clearing paths in `AuthLifecycleController` / `AppState`:
   - If `currentMode` is `.portal` or `.storage`, **`navigateTo(.landing)`** (or `navigateBack` until not gated).
   - Optionally open login sheet only if the user was mid-Portal/Storage action.
2. Ensure silent-reauth failure that clears auth does the same mode reset.
3. Unit/UI-ish test: authenticated → portal → expire → `currentMode == .landing`.

### Phase B — Soften the in-mode gate (P0/P1)

Prefer **not** showing the chrome-less `loginRequiredView` as the sole window content:

**Option 1 (recommended):** Never leave signed-out users on Portal/Storage mode — always redirect to landing + login sheet (same as tile/menu). Then `loginRequiredView` becomes dead code on macOS (keep for iOS home if needed).

**Option 2:** Keep mode but **always show mode chrome** (`showsModeChrome == true`) so Back / Home / Settings remain visible above the lock prompt.

**Option 3:** Overlay lock on Landing instead of replacing `modeBody`.

Ship **Option 1** unless product wants deep-linking into Portal while signed out.

### Phase C — Copy & discoverability (P1)

1. Login prompt subtitle: “Sign in to use Portal and Storage. Search, viewers, and Workflows work without an account.”  
2. Landing: keep Portal/Storage locked badges; ensure other tiles never show the full-window gate.

### Phase D — Related (later, not this bug)

1. Attach Bearer for proprietary CAOM2 / downloads (Windows CAOM2 parity).  
2. Inline “Sign in” on observation detail when 401/403.  
3. Gate Image Discovery / `run_code` as **actions**, not landing locks.

---

## Acceptance

- [ ] Signed out on Landing: Portal/Storage locked; Search / Research / FITS / Cube / Workflows open.  
- [ ] Session expire while in Portal/Storage → Landing (or chrome with clear Back), **not** a chrome-less full-window wall.  
- [ ] Logout while in Portal/Storage → Landing.  
- [ ] Menu/tile Portal/Storage while signed out → login sheet; free modules still reachable.  
- [ ] French strings for any new copy.

## Key files

- `Verbinal/Views/ContentView.swift` — `loginRequiredView`, `showsModeChrome`, `portalBody`, `storageBody`  
- `Verbinal/Views/LandingView.swift` — `navigateOrPromptLogin`  
- `Verbinal/ViewModels/AppState.swift` — logout / `updateAuthState` / mode  
- `Verbinal/ViewModels/AuthLifecycleController.swift` — expire / clear auth  
- `Verbinal/VerbinalApp.swift` — ⌘5 / ⌘6  

## Effort

| Phase | Size |
|-------|------|
| A | S |
| B | S |
| C | S |
| D | M (separate) |
