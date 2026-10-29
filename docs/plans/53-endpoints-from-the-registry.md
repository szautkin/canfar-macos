# Plan 53 — Endpoints from the registry: every service where the registry says, live

**Status: steps 1–5 and part E built on branch `1_4_2` (2026-10-28), committed 2026-10-29. Live cases
L1–L4 are left.**

The person (2026-10-28), after Skaha answered "HTTP 400: cannot get group memberships for anonymous" with
the account shown signed in: "we need to update our endpoints based on this reg ->
https://cadc-west-01.canfar.net/reg/resource-caps", then "we should expect that other services might
move so, we need to use reg properly".

## What happened

- **The account service moved.** The registry lists `ivo://cadc.nrc.ca/gms` and `ums` at
  `https://cadc-west-01.canfar.net/ac`.
- **The old services are not usable.** `ws-cadc.canfar.net/ac` reports `available: false`, "service is
  in read-only mode", and `ws-uv.canfar.net/ac` answers 503, "No server is available".
- **Verbinal kept signing in at the old service.** It takes its endpoints once, in `AppState.init`. It
  asks the registry in the background, at most once a day, and only a relaunch applies the answer.
  - The person's Debug build started at 17:17:05 with a stale cache, so sign-in and whoami went to
    `ws-cadc`.
  - The refresh that found `cadc-west-01` landed at 17:29, after the screenshot, and was not applied.
- **Whoami at the old service refused even a fresh token (403).** At 16:33 a password sign-in got a
  token there, and whoami refused it in the same second. Skaha, which checks identity with the new
  service, treated the requests as anonymous.
- **Most URLs are a resolved root plus a fixed path.** `/login`, `/v1/session` and the rest are not taken
  from the capabilities each service publishes. `acBaseURL` is not resolved at all.

## Principles

1. **The registry is the source of truth.** Each URL Verbinal calls comes from the capability that
   publishes it, by standard ID. The CANFAR defaults are only for when no registry answer was ever
   had.
2. **Live.** Services read the endpoints in use on every request. A refresh or an override applies
   at once, with no relaunch.
3. **Fresh before it matters, again when something fails.** Launch waits briefly for a stale registry
   before signing in. A service that stops answering asks the registry again.
4. **The person's overrides win**, field by field, as now.

## A. Endpoints that can change (VerbinalKit)

- **A1. `EndpointsSource`.** A protocol with one requirement, `current: APIEndpoints`.
  - `APIEndpoints` conforms with itself: fixed, for tests and previews.
  - **`LiveEndpoints`**, a Sendable class with a lock, conforms with the value in use, and `update`
    replaces it.
- **A2. Services take `any EndpointsSource`.**
  - Each keeps `private var endpoints: APIEndpoints { source.current }`, so the code that builds URLs
    is unchanged.
  - The services: AuthService, SessionService, HeadlessService, PlatformService, StorageService,
    ImageService, VOSpaceBrowserService, DownloadService, CutoutService.
  - `TAPConfig` reads a source too. `AppState` holds the `LiveEndpoints`, and `appState.endpoints`
    reads it.

## B. URLs from capabilities

- **B1. `ServiceCapability`.** Each URL Verbinal calls, with its resource ID and standard ID:

  | Capability | Resource | Standard ID | URL built from it |
  |---|---|---|---|
  | login | `ivo://cadc.nrc.ca/gms` | `ivo://ivoa.net/std/UMS#login-0.1` | `loginURL` |
  | whoami | gms | `…/UMS#whoami-0.1` | `whoAmIURL` |
  | users | gms | `…/UMS#users-0.1` | `userURL(_:)` |
  | sessions | `ivo://cadc.nrc.ca/skaha` | `http://www.opencadc.org/std/platform#session-1` | `sessionsURL`, `sessionURL(_:)`, events, logs, renew, apps, `statsURL` |
  | images | skaha | `…/platform#image-1` | `imagesURL` |
  | context | skaha | `…/platform#context-1` | `contextURL` |
  | repository | skaha | `…/platform#repository-1` | `repositoryURL` |
  | nodes | `ivo://cadc.nrc.ca/arc` | `ivo://ivoa.net/std/VOSpace/v2.0#nodes` | `storageBaseURL` (+ `/home`), as now |
  | tap | `ivo://cadc.nrc.ca/argus` | `ivo://ivoa.net/std/TAP` | `tapSyncURL` (+ `/sync`) |
  | datalink | `ivo://cadc.nrc.ca/caom2ops` | `ivo://ivoa.net/std/DataLink#links-1.1` | `datalinkURL` |
  | meta | caom2ops | `vos://cadc.nrc.ca~vospace/CADC/std/CAOM2#obs-1.0` | `caom2MetaURL` |
  | pkg | caom2ops | `…/CADC/std/Pkg-1.0` | `caom2PkgURL` |
  | resolver | `ivo://cadc.nrc.ca/resolver` | `…/CADC/std/NameResolver#names-1.0` | `targetResolverURL` |
  | files | `ivo://cadc.nrc.ca/data` | `…/CADC/std/archive#file-1.0` | `dataPubURL(forArtifactURI:)` |

- **B2. Built from the capability first.** `APIEndpoints` carries the resolved capability URLs. Each
  derived URL uses its capability's when there is one, and otherwise today's base plus path. A field
  the person overrode drops its service's capability URLs, so the override wins.
- **B3. `acBaseURL` resolves from `ivo://cadc.nrc.ca/ums`.**
- **B4. The defaults follow the registry of today.** Login and AC are `https://cadc-west-01.canfar.net/ac`.

## C. When the registry is asked

- **C1. Launch.** The registry is asked before the stored sign-in is checked, when its answer is older
  than 6 hours (it was 24). Launch waits for it at most 5 seconds. A later answer applies live.
- **C2. Back at the front.** A stale answer is asked again when the app becomes active.
- **C3. A service that fails.** A 502 or 503 from a CADC or CANFAR host, or no connection to it, asks
  the registry again. At most once in 5 minutes. When the answer moves the service, the next request
  goes there. A 404 does not ask: it is usually about the thing asked for, not the service.
- **C4. Applying an answer.** It updates `LiveEndpoints`, the token's host allow-list and `TAPConfig`.
  A service that moved is recorded in the decision log: "… is now at …: the registry moved it".
- **C5. Overrides apply live too.** The relaunch banner goes (`pendingRelaunch`,
  `resolvedChangesPendingRelaunch`, `activeAtLaunch`).

## D. Settings ▸ Endpoints and the manual

- **D1.** Each field shows its source (override, registry, default) and when the registry last answered.
  The relaunch section goes.
- **D2.** Chapter 14 (en, fr): the registry is followed live, and an override applies at once.

## E. Found here, then fixed (the person: "yes", 2026-10-28)

The sign-in gaps of the investigation:
1. `validateToken` sets the token it checks as the live one, and clears it on 401 or 403.
2. The launch check runs from each main window's `.task`.
3. "Validating session..." can be left behind.
4. Skaha's "for anonymous" 400, and a refused whoami, are shown raw.

How each was fixed (tests in `RenewalTests`):
1. **E1.** `validateToken` sends the token it checks on that request alone. It installs it only when
   CADC accepts it, and never clears the live one. An ended session clears it, through
   `AuthService.logout()`.
2. **E2.** `validateStoredToken` returns at once while signed in or while a check is under way.
3. **E3.** A launch check that ends in a renewal says "Welcome".
4. **E4.** Three changes:
   - Skaha's anonymous 400, for a request that carried a token, goes through the sign-in check once, so
     an expired token renews or asks to sign in. A token CADC accepts is not signed in again for it, and
     the error says what it means.
   - A request sent without a token is expected to be anonymous, so it is not checked. The full suite
     showed why: fixtures signed in without a token were ended by real Skaha answers.
   - Whoami's 403 while the account service's VOSI availability says not available is `.unavailable`:
     the session and the password are kept, with the service's own words.
   - `get_service_health` asks the account service's availability, and a 200 that says not available
     is `degraded` (`VOSIAvailability`).

## Steps (tests first where they can fail)

1. A1–A2: live endpoints. No behavior change; the build and tests pass as they are.
2. B1–B4: URLs from capabilities. VerbinalKit tests: each derived URL prefers its capability, and
   falls back to base plus path.
3. Registry resolution by standard ID, `acBaseURL`, live apply (C4, C5). App tests with a fake
   registry:
   - a moved login applies without relaunch;
   - an override wins;
   - a registry that cannot be reached keeps the cache, then the defaults.
4. C1–C3: launch wait, return to the front, failure re-asks. Tests: launch waits for a stale registry
   at most the bound; failures re-ask once per window.
5. D: Settings and manual.

## Where it stands (2026-10-28)

Built as planned, with these additions:
- **Health probes.** `get_service_health` and Settings ▸ Endpoints ▸ Test Connections ask each service
  where the registry publishes its availability (`APIEndpoints.serviceRoots`). The tool builds its list
  when called, not at launch.
- **No duplicate nodes URL.** Storage's `nodes` capability becomes `storageBaseURL`, not a capability
  URL.
- **Splits for the file budget.** `NetworkClient` gave up two extensions, `+ServiceTrouble` and
  `+TrustedHosts`, and its ceiling went from 719 to 693.

Seen against the live registry by a throwaway test:
- all 13 capabilities resolved;
- sign-in, whoami and users at `cadc-west-01.canfar.net/ac`;
- Skaha and the archive URLs as published.

Tests:
- The whole Mac suite (2,401) ran. Two failures were this plan's and were fixed: the file budget, and
  a test that expected `acBaseURL` to have no resource. The two known failures remain:
  `SidecarKeeperTests` (sandboxed bind in /tmp) and `EveryScreenNamedTests` settings.agent.
- The package tests pass, and iOS builds.

## Live cases

- **L1.** With a stale cache, launch signs in at `cadc-west-01.canfar.net/ac`, and Skaha answers.
- **L2.** Settings ▸ Endpoints shows each field from the registry, with no relaunch banner.
- **L3.** Overriding Skaha's base applies at once (Portal reloads from it); clearing it returns to the
  registry's.
- **L4.** With the registry unreachable, the app works from its cache.
