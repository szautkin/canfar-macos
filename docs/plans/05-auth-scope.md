# Dev plan — Auth scope: don’t block the whole app

**Status:** Phase A/B + review fixes shipped · Phase C/D later  
**Surface:** macOS ContentView / Landing / session-expiry  
**Related:** [Global plan](./00-global.md)

## Findings

### Intended design (already correct)

Auth is **not** meant to gate the whole app. Only:

| Surface | Auth |
|---------|------|
| **Portal** | Required (`AppMode.requiresAuthentication`) |
| **Storage** | Required |
| Search, Research, FITS, Cube, Workflows, AI Guide, FileBrowser, Settings | Open without login |

This matches Windows (`RequiresAuth` only on Portal + Storage) and the landing tiles (`locked` only on those two). Menu ⌘5 / ⌘6 use `navigateOrPromptLogin`.

### Why it *felt* like a global block

The chrome-less “Login Required” body appeared when Portal/Storage stayed selected after logout/expiry with `isAuthenticated == false`. That path is fixed: leave gated modes on confirmed expiry/logout; keep auth live through silent reauth.

---

## Goals

1. Signed-out users always keep access to Landing + free modules.  
2. Portal/Storage never present a chrome-less full-window wall that feels global.  
3. Session expiry / logout bounce out of Portal/Storage.  
4. Keep Windows parity: only Portal + Storage require auth to enter.

---

## Approach

### Phase A — Session expiry / logout UX (P0) ✅

- Confirmed expiry / logout → `leaveAuthGatedModesIfNeeded` → Landing.  
- Expiry remembers destination for login return; logout does not.  
- Pending restore only while `currentMode == .landing` (no hijack of free modules).

### Phase B — Soften the in-mode gate (P0/P1) ✅ Option 1

Never leave signed-out users on Portal/Storage after expiry/logout. Silent reauth keeps `isAuthenticated` true until `.sessionExpired`. `loginRequiredView` remains a safety net.

### Review follow-ups ✅

1. Pending restore gated to Landing; free-module `navigateTo` clears pending.  
2. Auth flag matches session truth through silent reauth; suspend hook removed.  
3. `AppMode.requiresAuthentication` + `AppState.navigateOrPromptLogin`.

### Phase C — Copy & discoverability (P1)

1. Login prompt subtitle: “Sign in to use Portal and Storage. Search, viewers, and Workflows work without an account.”  
2. Landing: keep Portal/Storage locked badges; ensure other tiles never show the full-window gate.

### Phase D — Related (later, not this bug)

1. Attach Bearer for proprietary CAOM2 / downloads (Windows CAOM2 parity).  
2. Inline “Sign in” on observation detail when 401/403.  
3. Gate Image Discovery / `run_code` as **actions**, not landing locks.  
4. Optional: MCP `navigate_to` through `navigateOrPromptLogin`.

---

## Acceptance

- [x] Signed out on Landing: Portal/Storage locked; Search / Research / FITS / Cube / Workflows open.  
- [x] Session expire while in Portal/Storage → Landing + login sheet (not chrome-less wall).  
- [x] Logout while in Portal/Storage → Landing.  
- [x] Silent reauth success keeps Portal/Storage without Landing bounce.  
- [x] Menu/tile Portal/Storage while signed out → login sheet; free modules still reachable.  
- [x] Pending restore does not hijack free modules.  
- [ ] French strings for any new copy (Phase C).

## Key files

- `Verbinal/ViewModels/AppState.swift` — `requiresAuthentication`, `navigateOrPromptLogin`, leave/pending  
- `Verbinal/ViewModels/AuthLifecycleController.swift` — silent reauth keeps auth until expiry  
- `Verbinal/Views/ContentView.swift` — `loginRequiredView` (safety net), `showsModeChrome`  
- `Verbinal/Views/LandingView.swift` / `Verbinal/VerbinalApp.swift` — prompt helper  

## Effort

| Phase | Size |
|-------|------|
| A | S ✅ |
| B | S ✅ |
| Review fixes | S ✅ |
| C | S |
| D | M (separate) |
