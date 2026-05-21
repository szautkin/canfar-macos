# Verbinal Inspector Image — Build Requirements

This document describes the container image Verbinal uses as the **inspector
host** for the Image Discovery feature: it runs `syft` against a target
image's registry manifest and writes a JSON package inventory to the user's
VOSpace.

When you build your own inspector image and push it to a registry Skaha can
pull (Harbor, Docker Hub, Quay, GHCR, etc.), point Verbinal at it via
**Settings → Image Discovery → Inspector image**.

---

## 1. Why a custom inspector image

Verbinal ships with `images.canfar.net/skaha/terminal:1.1.2` as the default
inspector host. When that image becomes inaccessible to your Skaha account
(registry policy change, Harbor permissions, tag rotation), every probe job
fails at submit time with:

```
HTTP 400: No authentication provided for unknown or private image.
Use x-skaha-registry-auth request header with base64Encode(username:secret).
```

The fix is to (a) point Verbinal at an image you control or one you've
verified is still pullable, and (b) optionally supply registry credentials so
Skaha can pull private images on your behalf. Both are configured in
**Settings → Image Discovery**.

---

## 2. Mandatory requirements

The inspector image must satisfy **all** of these. Verbinal will probe-launch
it as a Skaha headless job; missing tools cause the probe to fail silently
(empty manifest with `probeNotes`).

| Requirement                  | Why                                                 | How to verify                  |
| ---------------------------- | --------------------------------------------------- | ------------------------------ |
| **`bash` ≥ 4.0**             | Inspector script is a bash heredoc.                 | `bash --version`               |
| **`python3` ≥ 3.7**          | JSON transformer (syft SBOM → ImageManifest).       | `python3 -V`                   |
| **`curl` or `wget`**         | Downloads the `syft` static binary at runtime.      | `command -v curl wget`         |
| **Outbound HTTPS to GitHub** | Fetches `raw.githubusercontent.com/anchore/syft/`.  | `curl -I https://raw.githubusercontent.com/anchore/syft/main/install.sh` |
| **Outbound HTTPS to target registries** | `syft` reads remote registry manifests. | `curl -I https://images.canfar.net/v2/` |
| **`mv`, `mktemp`, `tr`, `head`, `sed`** | Standard POSIX file plumbing. | `command -v mv mktemp tr head sed` |
| **Skaha `headless` type**    | Image must be registered as headless-launchable on Skaha. | List in `list_session_images.type = headless` |
| **Writable `$HOME`**         | Inspector writes `~/.verbinal/manifests/<id>.json`. | `touch $HOME/.verbinal-test && rm $HOME/.verbinal-test` |
| **VOSpace mount at `/arc/home/$USER/`** | Skaha auto-mounts when launching as the logged-in user. | N/A — Skaha-side |
| **CPU architecture: `linux/amd64`** | Matches Skaha cluster nodes. | `uname -m` reports `x86_64` |

## 3. Strongly recommended

These improve probe reliability and latency but aren't strictly required.

| Recommendation                  | Why                                                          |
| ------------------------------- | ------------------------------------------------------------ |
| **Image size ≤ 500 MB**         | Faster Skaha pulls; probes complete in <60s instead of 3-5 minutes. |
| **`syft` pre-installed** at `/usr/local/bin/syft` | Skips the curl-install step. Saves ~30s per probe; survives outbound-network restrictions. |
| **Pinned tag, not `:latest`**   | Reproducible probes. `:latest` can drift between runs.       |
| **`set -o pipefail` compatibility** | Inspector script enables `pipefail`; broken pipes surface immediately. |
| **Non-root user**               | Best practice; not enforced by Skaha but reduces blast radius if syft is ever exploited. |

## 4. NOT required (but harmless to include)

The inspector path explicitly does **not** introspect the host image's own
packages — it only inspects the *target* image via `syft registry:<target>`.
So the host image doesn't need:

- Any specific Python packages (no astropy, no fitsio, etc.).
- `pip` or `conda` (the inspector uses neither).
- `R` / `Rscript`.
- GUI libraries.
- A specific OS distribution (any Debian/Ubuntu/Alpine/AlmaLinux/RHEL is fine
  as long as bash + python3 + curl work).

## 5. Minimum viable Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.6
# Slim Debian + bash + python3 + curl + pre-installed syft.
# Total image size: ~120 MB.
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        python3 \
 && rm -rf /var/lib/apt/lists/*

# Pre-install syft so the inspector script's curl|sh step is a no-op.
# Pinning the version means probes are reproducible — bump deliberately.
ARG SYFT_VERSION=1.18.1
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
        | sh -s -- -b /usr/local/bin v${SYFT_VERSION} \
 && syft --version

# Skaha launches headless jobs as the user (uid mapped from CADC SSO),
# with $HOME bound to /arc/home/<username>/. We don't need a USER
# directive — Skaha overrides it.

# A no-op default command. Verbinal supplies `cmd: bash`, `args: <path>`.
CMD ["bash"]
```

Build, tag, and push:

```bash
docker buildx build --platform linux/amd64 \
    -t images.canfar.net/<your-project>/verbinal-inspector:1.0.0 \
    --push .
```

Then ask the CANFAR admin team to mark
`images.canfar.net/<your-project>/verbinal-inspector` as **headless**-typed in
Skaha. Once it appears in `list_session_images(type: "headless")`, point
Verbinal at it via Settings.

## 6. Verifying the image works

After pushing and tagging the image as headless on Skaha:

1. **Launch a one-shot session manually** with `cmd: bash`, `args: -c 'echo hello'` —
   confirms Skaha can pull and start the image.
2. **Open Verbinal → Settings → Image Discovery** and paste the full image
   id (e.g. `images.canfar.net/<project>/verbinal-inspector:1.0.0`) into the
   *Inspector image* field. If the image lives in a private namespace, also
   fill in *Username* and *Secret* (one-time; cached in macOS Keychain).
3. **Trigger a Rediscover** on any non-headless image from the discovery
   sheet. If the probe completes with a populated manifest, the image is
   working. If it stays in "Probing…" past 5 minutes, check the Background
   Jobs panel for the inspector job's logs.

## 7. Update / maintenance

- Bump `SYFT_VERSION` in the Dockerfile when [Anchore releases a major version](https://github.com/anchore/syft/releases). Verbinal pins to v3 of the syft JSON schema; v4+ may need an inspector script update.
- Rebuild + push with a new pinned tag (`1.0.1`, `1.1.0`, etc.). Don't reuse `:latest` — Verbinal's manifest cache uses the tag for content-hash invalidation.
- The CANFAR admin team needs to re-tag the new version as headless. The old one keeps working until its tag is removed from the catalog.

## 8. Troubleshooting

| Symptom                                          | Likely cause                                              |
| ------------------------------------------------ | --------------------------------------------------------- |
| Probe submits, then job stays Pending 15+ min    | Image isn't tagged headless on Skaha, or the cluster is busy. Check `list_session_images` includes your tag with `headless` in `types`. |
| Probe completes but manifest has `probeNotes: "syft scan returned no recognisable packages"` | The target image was pulled and scanned, but has no recognisable packages (rare — minimal scratch images). |
| Probe fails with `syft missing; minimal manifest written` | `curl`/`wget` couldn't reach `raw.githubusercontent.com`. Pre-install syft (recommended in §3). |
| Probe fails with `python3 not found` | Image lacks python3. Add `python3` to the apt install list. |
| Probe completes but the manifest is empty / all zero-length lists | The transformer ran but syft's JSON was empty. Check inspector image's outbound HTTPS to the *target* image's registry — corporate proxies often block by registry hostname. |
| Recurring HTTP 400 "unknown or private image" at submit | Either (a) the inspector image isn't pullable by Skaha for your account → verify registry credentials, or (b) the inspector image isn't tagged headless → ask the admin. |
