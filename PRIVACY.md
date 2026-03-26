# Privacy Policy — Verbinal for macOS

**Effective date:** 25 March 2026
**App name:** Verbinal — A CANFAR Science Portal Companion (macOS)
**Publisher:** Serhii Zautkin

## Summary

Verbinal does not collect, transmit, or sell any personal data to the developer or to any third party. All data stays on your device or is sent directly to the CANFAR services you choose to authenticate with.

## 1. Data we collect

**None.** Verbinal has no backend, analytics, telemetry, crash reporting service, or advertising SDK.

## 2. Data stored on your device

Verbinal stores the following information locally:

| Data | Location | Purpose |
|---|---|---|
| CANFAR authentication token | macOS Keychain | Keeps you signed in between sessions when credentials are saved |
| CANFAR username | macOS Keychain | Identifies the account associated with the saved token |
| Recent session launches | `~/Library/Application Support/Verbinal/recent_launches.json` | Shows your recent launch history for quick re-launch |

Saved credentials are removed when you log out.

## 3. Data sent over the network

Verbinal communicates exclusively with CANFAR services operated by the Canadian Astronomy Data Centre and the Digital Research Alliance of Canada. All connections use HTTPS.

| Endpoint | Data sent | Purpose |
|---|---|---|
| `ws-cadc.canfar.net/ac/login` | Username and password | Authentication |
| `ws-cadc.canfar.net/ac/whoami` | Authentication token | Token validation |
| `ws-uv.canfar.net/ac` | Authentication token | User profile retrieval |
| `ws-uv.canfar.net/skaha` | Authentication token | Session management, image listing, platform stats |
| `ws-uv.canfar.net/arc` | Authentication token | Storage quota retrieval |

Verbinal does not contact analytics endpoints, ad networks, or third-party SDK services.

## 4. Third-party services

Verbinal does not integrate with third-party services. The only external communication is with CANFAR services.

## 5. Your choices

- Do not save credentials if you do not want persistent login state.
- Log out to clear saved credentials from Keychain.
- Clear recent launches from the app UI.

## 6. Changes to this policy

If this policy changes, the updated version will be published in the source repository and the effective date above will be updated.

## 7. Contact

- GitHub: open an issue in the repository
- Developer: Serhii Zautkin

This privacy policy applies to the Verbinal for macOS application distributed via source code under the AGPL-3.0 license.
