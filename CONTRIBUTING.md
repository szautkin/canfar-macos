# Contributing to Verbinal for macOS

Thank you for your interest in contributing. This document provides the baseline workflow for changes to the macOS client.

## Getting Started

1. Fork the repository.
2. Clone your fork and create a branch:
   ```bash
   git clone git@github.com:YOUR_USERNAME/canfar-macos.git
   cd canfar-macos
   git checkout -b my-feature
   ```
3. Install Xcode and XcodeGen.
4. Generate the project and verify the app:
   ```bash
   xcodegen generate
   xcodebuild build \
     -project Verbinal.xcodeproj \
     -scheme Verbinal \
     -destination 'platform=macOS' \
     -derivedDataPath .derivedData \
     CODE_SIGNING_ALLOWED=NO
   xcodebuild test \
     -project Verbinal.xcodeproj \
     -scheme Verbinal \
     -destination 'platform=macOS' \
     -derivedDataPath .derivedData \
     CODE_SIGNING_ALLOWED=NO
   ```

## Gates

Every commit passes all three. `.xcode-version` names the Xcode used for
development (CI runs the `macos-15` image's default Xcode).

```bash
# 1. App build + tests (macOS)
xcodebuild test -project Verbinal.xcodeproj -scheme Verbinal \
  -destination 'platform=macOS' -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO

# 2. Shared package tests
(cd shared/VerbinalKit && swift test)

# 3. iOS target, whenever shared code changes
xcodebuild build -project Verbinal.xcodeproj -scheme VerbinalIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

A change adds no compiler warnings.

## Code Style

- Keep views thin; prefer services and view models for behavior.
- Prefer small, testable units for parsing, state transitions, and request construction.
- Run `xcodegen generate` after changing `project.yml`.
- Add or extend unit tests when you introduce non-UI logic.
- Avoid introducing secrets, machine-specific paths, or generated build artifacts into the repository.

## Pull Requests

1. Ensure the project builds cleanly.
2. Run the test suite and include relevant verification details.
3. Keep changes focused on one feature or fix.
4. Write a clear PR description that explains the change and rationale.
5. Include screenshots for UI changes when relevant.

## Reporting Issues

- Use the GitHub issue tracker.
- Include your macOS version and Xcode version.
- Include reproduction steps and any build or runtime error output.

## License

By contributing, you agree that your contributions will be licensed under the [MPL-2.0 license](LICENSE).
