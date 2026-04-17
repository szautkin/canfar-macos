# App Review Notes — Verbinal

**Paste into App Store Connect → App Information → Notes for Review when submitting.**

---

Verbinal is a native macOS client for the Canadian Astronomy Data Centre
(CANFAR) Science Portal. It lets astronomers query CADC archives, browse
VOSpace storage, view FITS images, run Jupyter notebooks locally, and export
search results — all from their institutional CADC account.

## Test account

Reviewers can use the following CADC test account to exercise every feature:

  Username: **<TODO: provision a CADC test account before submitting>**
  Password: **<TODO>**

CADC accounts are free to create at https://www.canfar.net/ — the Sign Up link
is also prominent inside the app's login sheet.

## Guideline 5.1.1(v) — Sign in with Apple exemption

Verbinal authenticates users against CANFAR's own institutional account system
(an OIDC service hosted by the Canadian Space Agency and NRC-Herzberg). The
app makes no use of Facebook, Google, Apple, or any consumer social login
provider.

CADC accounts are required to access the underlying scientific data services;
the portal cannot be used without one. This matches the explicit exemption in
Guideline 5.1.1(v):

  "The following apps are exempt from this requirement: Apps that
   exclusively use a company's own account setup and sign-in systems.
   Apps that are an education, enterprise, or business app that
   requires the user to sign in with an existing education or
   enterprise account."

Verbinal is an education/research app that exclusively uses the CANFAR account
system, so adding Sign in with Apple would not be meaningful — there is no
corresponding CADC account to link it to.

## Guideline 2.5.2 — Bundled Python

The app ships a relocatable CPython 3.12 distribution inside
`Contents/Resources/python/`, used exclusively to execute cells in the in-app
Jupyter notebook feature.

To comply with 2.5.2, pip, setuptools, wheel, and ensurepip are stripped at
build time (`scripts/bundle-python.sh`). The interpreter has no ability to
download or install additional packages at runtime. Users can only execute
code they type into the notebook themselves, which runs in a sandboxed
subprocess under the parent's sandbox profile (`com.apple.security.inherit`).

The scientific libraries bundled (numpy, astropy, matplotlib) are the minimum
needed to make the notebook feature useful for astronomy workflows.

## Hardened-runtime entitlement justifications

Verbinal is hardened-runtime-signed and sandboxed. Two cs.* entitlements are
enabled, both required by the bundled CPython:

  com.apple.security.cs.disable-library-validation
    CPython loads C-extension .so files (numpy, matplotlib, astropy C core,
    pillow, pyerfa, etc.) that are signed with the app's own identity rather
    than Apple's platform identity. Without this key, dyld refuses to map them.

  com.apple.security.cs.allow-unsigned-executable-memory
    Numpy's BLAS shim and matplotlib's Agg backend use ctypes to call into
    C code that requires writable-then-executable pages on some allocation
    paths. CPython itself does not JIT.

Both entitlements apply only to the main app process; the sandboxed Python
subprocess inherits them via `com.apple.security.inherit` but cannot escape
the parent's sandbox because it has no entitlements of its own beyond inherit.

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
`ITSAppUsesNonExemptEncryption = NO` is set in Info.plist under §740.17(b)(3)(iii)(A).
No CCATS or annual self-classification report required.

## What to try

1. Launch app → click Login → enter the test credentials above.
2. Portal tab: browse available container images and session profiles.
3. Search tab: run an ADQL query (the preset "CFHT r-band observations"
   works with the public data).
4. Results → pick any row → Download — saves a FITS file to the user-chosen
   location via NSSavePanel.
5. FITS Viewer tab: open the downloaded FITS file, zoom, change stretch
   (linear / log / sqrt), toggle colormap. Crosshair shows WCS coordinates.
6. Notebook tab: open `<TODO: ship a demo .ipynb in the test assets>` and
   execute a cell that does `import numpy, astropy`. First-time launch of
   the kernel may take ~2 seconds.
7. Storage tab: browse the test account's VOSpace home directory.
8. Export tab: create a Claude-friendly bundle with search history and
   research observations.

## Contact

Any questions during review please reach me at:
  Email: <TODO — support address>
  Response time: within 24 hours on weekdays.

Source is MPL-2.0 at https://github.com/szautkin/canfar-macos.
