# App Review Notes — Verbinal

**Paste into App Store Connect → App Information → Notes for Review when submitting.**

---

Verbinal is a native macOS client for the Canadian Astronomy Data Centre
(CANFAR) Science Portal. Astronomers use it to query CADC archives, browse
VOSpace storage, view FITS images, and manage their research observation
library — all against their institutional CADC account.

## Test account

Reviewers can use the following CADC test account to exercise every feature:

  Username: **<TODO: provision a CADC test account before submitting>**
  Password: **<TODO>**

CADC accounts are free to create at https://www.canfar.net/. The Sign Up
link is also prominent inside the app's login sheet.

## Guideline 5.1.1(v) — Sign in with Apple exemption

Verbinal authenticates users against CANFAR's own institutional account system
(an OIDC service hosted by the Canadian Space Agency and NRC-Herzberg). The
app makes no use of Facebook, Google, Apple, or any consumer social login
provider. CADC accounts are required to access the underlying scientific data
services; the portal cannot be used without one.

This matches the explicit exemption in Guideline 5.1.1(v):

  "The following apps are exempt from this requirement: Apps that
   exclusively use a company's own account setup and sign-in systems.
   Apps that are an education, enterprise, or business app that
   requires the user to sign in with an existing education or
   enterprise account."

Verbinal is an education/research app that exclusively uses the CANFAR account
system, so adding Sign in with Apple would not be meaningful — there is no
corresponding CADC account to link it to.

## Sandbox profile

Verbinal ships with App Sandbox enabled and only the minimum entitlements:

  com.apple.security.app-sandbox
  com.apple.security.network.client
  com.apple.security.files.user-selected.read-write
  com.apple.security.files.downloads.read-write
  keychain-access-groups

No hardened-runtime override entitlements are used. No subprocess spawning,
no JIT, no downloaded executable code. The app is a straightforward SwiftUI
client that makes HTTPS calls to CADC and displays FITS images the user
downloads via NSSavePanel.

## Privacy manifest

`PrivacyInfo.xcprivacy` declares:

  - Data collection: User ID + Credentials, linked to user, not for tracking,
    purpose "App functionality". These are the user's CADC username/password
    that the app transmits (over TLS) to CANFAR's authentication service at
    the user's direction. Verbinal operates no servers of its own.
  - Required-reason APIs:
      NSPrivacyAccessedAPICategoryUserDefaults (CA92.1)
      NSPrivacyAccessedAPICategoryFileTimestamp (3B52.1 + DDA9.1)
  - No tracking, no ad SDKs, no analytics, no third-party telemetry.

## Export compliance

The app uses only URLSession / TLS (Apple's platform encryption).
`ITSAppUsesNonExemptEncryption = NO` is set in Info.plist under
§740.17(b)(3)(iii)(A). No CCATS or annual self-classification report required.

## What to try

1. Launch app → click Login → enter the test credentials above.
2. Portal tab: browse available container images and session profiles.
3. Search tab: run an ADQL query (the preset "CFHT r-band observations"
   works with the public data).
4. Results → pick any row → Download — saves a FITS file to the user-chosen
   location via NSSavePanel.
5. FITS Viewer tab: open the downloaded FITS file, zoom, change stretch
   (linear / log / sqrt), toggle colormap. Crosshair shows WCS coordinates.
6. Storage tab: browse the test account's VOSpace home directory.
7. Export tab: create a shareable bundle with search history and research
   observations.

Note for reviewers: Verbinal is the slim SKU in a two-product family. A
companion app **Verbinal Pi** (bundle id `com.codebg.VerbinalPi`) adds a
Jupyter-style notebook with a bundled CPython 3.12 interpreter; that SKU is
submitted separately with its own review notes covering the additional
hardened-runtime entitlements.

## Contact

Any questions during review please reach me at:

  Email: <TODO — support address>
  Response time: within 24 hours on weekdays.

Source is MPL-2.0 at https://github.com/szautkin/canfar-macos.
