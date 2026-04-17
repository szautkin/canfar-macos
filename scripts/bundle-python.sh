#!/usr/bin/env bash
# Build the bundled Python distribution that ships inside Verbinal.app.
#
# Stages:
#   1. Download python-build-standalone (CPython 3.12, arm64-apple-darwin, install_only).
#   2. Extract to build cache under $CACHE_DIR (idempotent — skipped when cache hit).
#   3. `pip install` the scientific baseline (numpy, astropy, matplotlib) into the extracted prefix.
#   4. Strip extraneous files (tests, __pycache__, pip docs) to keep size down.
#   5. Codesign every embedded Mach-O binary with the runtime's hardened settings.
#   6. Copy the final tree to $OUTPUT_DIR (expected to be an Xcode-supplied per-build path).
#
# Inputs  (env):
#   PYTHON_VERSION         — CPython version, e.g. 3.12.7. Default pulled from PBS_INDEX_TAG below.
#   PBS_INDEX_TAG          — python-build-standalone release tag. Update both together.
#   ARCH                   — arm64 (default) | x86_64 | universal2 (universal2 requires two downloads).
#   CACHE_DIR              — where the downloaded + extracted distribution is cached. Default: .python-bundle-cache
#   OUTPUT_DIR             — destination prefix. Default: $CACHE_DIR/python (so a local run works without Xcode).
#   SIGN_IDENTITY          — code-signing identity. Default: "-" (ad-hoc). Xcode provides the real identity.
#   EXPECTED_SHA256        — optional hash of the source tarball; when set the script aborts on mismatch.
#   SKIP_PACKAGES=1        — skip pip install step (for fast iteration).
#   SKIP_SIGNING=1         — skip codesign (only useful for local experiments; breaks sandboxed launch).
#   KEEP_PIP=1             — keep pip / setuptools / wheel in the final bundle. Default is to
#                            strip them so the app has no way to fetch/install code at runtime —
#                            required for Mac App Store submission (Review Guideline 2.5.2).
#
# Outputs:
#   $OUTPUT_DIR/bin/python3   — the relocatable interpreter.
#   $OUTPUT_DIR/lib/python3.12 — stdlib + site-packages with the bundled scientific stack.
#
# This script is intentionally idempotent: re-running with the same PYTHON_VERSION and package
# list reuses the cache and only re-runs steps whose inputs changed. Delete $CACHE_DIR to force.

set -euo pipefail

# ------------------------------------------------------------------
# Configuration — keep these two in sync.
# ------------------------------------------------------------------
PBS_INDEX_TAG="${PBS_INDEX_TAG:-20241016}"            # python-build-standalone release tag
PYTHON_VERSION="${PYTHON_VERSION:-3.12.7}"            # CPython version within that release
ARCH="${ARCH:-arm64}"

# ------------------------------------------------------------------
# Derived paths.
# ------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${CACHE_DIR:-$REPO_ROOT/.python-bundle-cache}"
OUTPUT_DIR="${OUTPUT_DIR:-$CACHE_DIR/python}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

case "$ARCH" in
    arm64)       PBS_TRIPLE="aarch64-apple-darwin" ;;
    x86_64)      PBS_TRIPLE="x86_64-apple-darwin"  ;;
    universal2)  echo "ERROR: universal2 not yet implemented — contact dev" >&2; exit 2 ;;
    *)           echo "ERROR: unsupported ARCH=$ARCH" >&2; exit 2 ;;
esac

TARBALL_NAME="cpython-${PYTHON_VERSION}+${PBS_INDEX_TAG}-${PBS_TRIPLE}-install_only_stripped.tar.gz"
DOWNLOAD_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_INDEX_TAG}/${TARBALL_NAME}"
TARBALL_PATH="$CACHE_DIR/$TARBALL_NAME"
EXTRACT_DIR="$CACHE_DIR/extracted-${PYTHON_VERSION}-${PBS_INDEX_TAG}-${ARCH}"

mkdir -p "$CACHE_DIR"

log() { printf '[bundle-python] %s\n' "$*"; }

# ------------------------------------------------------------------
# 1. Download (skip if cached).
# ------------------------------------------------------------------
if [[ ! -f "$TARBALL_PATH" ]]; then
    log "downloading $TARBALL_NAME"
    curl -fSL --retry 3 --retry-delay 2 -o "$TARBALL_PATH.part" "$DOWNLOAD_URL"
    mv "$TARBALL_PATH.part" "$TARBALL_PATH"
else
    log "tarball cached at $TARBALL_PATH"
fi

if [[ -n "${EXPECTED_SHA256:-}" ]]; then
    log "verifying sha256"
    actual="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"
    if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
        echo "ERROR: sha256 mismatch for $TARBALL_NAME" >&2
        echo "  expected: $EXPECTED_SHA256" >&2
        echo "  actual:   $actual" >&2
        exit 3
    fi
fi

# ------------------------------------------------------------------
# 2. Extract.
# ------------------------------------------------------------------
if [[ ! -d "$EXTRACT_DIR/python" ]]; then
    log "extracting to $EXTRACT_DIR"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$TARBALL_PATH" -C "$EXTRACT_DIR"
else
    log "extracted dir cached at $EXTRACT_DIR"
fi

PY_PREFIX="$EXTRACT_DIR/python"
PY_BIN="$PY_PREFIX/bin/python3"

if [[ ! -x "$PY_BIN" ]]; then
    echo "ERROR: $PY_BIN not executable after extraction" >&2
    exit 4
fi

# ------------------------------------------------------------------
# 3. Install scientific baseline.
# ------------------------------------------------------------------
PACKAGES_STAMP="$EXTRACT_DIR/.packages-installed"
REQUIRED_PACKAGES=(
    "numpy==2.1.*"
    "astropy==6.1.*"
    "matplotlib==3.9.*"
)

if [[ "${SKIP_PACKAGES:-0}" == "1" ]]; then
    log "SKIP_PACKAGES=1 — leaving site-packages untouched"
elif [[ -f "$PACKAGES_STAMP" ]] && \
     diff -q "$PACKAGES_STAMP" <(printf '%s\n' "${REQUIRED_PACKAGES[@]}") >/dev/null 2>&1; then
    log "packages already installed, skipping"
else
    log "installing: ${REQUIRED_PACKAGES[*]}"
    "$PY_BIN" -m pip install --no-cache-dir --upgrade pip >/dev/null
    "$PY_BIN" -m pip install --no-cache-dir "${REQUIRED_PACKAGES[@]}"
    printf '%s\n' "${REQUIRED_PACKAGES[@]}" > "$PACKAGES_STAMP"
fi

# ------------------------------------------------------------------
# 4. Strip caches. DO NOT touch "tests"/"test" subdirs blindly — some third-party
# packages (astropy.tests, sklearn.tests, etc.) expose their `tests` directory
# as a public submodule used by internal imports, so stripping them breaks
# `import astropy`. Only strip pycache and stdlib `test/` (always unused at runtime).
# ------------------------------------------------------------------
log "stripping caches"
find "$PY_PREFIX" -type d -name "__pycache__"  -prune -exec rm -rf {} + 2>/dev/null || true
find "$PY_PREFIX" -type f -name "*.pyc"        -delete                              2>/dev/null || true
# Remove only the stdlib's own self-test suite (safe; never imported at runtime).
rm -rf "$PY_PREFIX/lib/python3.12/test" 2>/dev/null || true
rm -rf "$PY_PREFIX/lib/python3.12/unittest/test" 2>/dev/null || true
rm -rf "$PY_PREFIX/lib/python3.12/lib2to3/tests" 2>/dev/null || true

# Strip package managers unless explicitly kept. App Store Review Guideline 2.5.2
# forbids apps from downloading and executing code not reviewed by Apple, so the
# bundled interpreter must not be able to fetch new packages at runtime.
if [[ "${KEEP_PIP:-0}" != "1" ]]; then
    log "stripping pip / setuptools / wheel (set KEEP_PIP=1 to retain — not MAS-safe)"

    # Binaries.
    rm -f "$PY_PREFIX/bin/pip" "$PY_PREFIX/bin/pip3" "$PY_PREFIX/bin/pip3."* 2>/dev/null || true
    rm -f "$PY_PREFIX/bin/wheel" "$PY_PREFIX/bin/wheel3" "$PY_PREFIX/bin/wheel3."* 2>/dev/null || true

    # Site-packages.
    SITE_PACKAGES="$PY_PREFIX/lib/python3.12/site-packages"
    for pkg in pip pip-*.dist-info _distutils_hack setuptools setuptools-*.dist-info \
               pkg_resources wheel wheel-*.dist-info; do
        rm -rf "$SITE_PACKAGES/"$pkg 2>/dev/null || true
    done

    # distutils command stubs (stdlib is slim without these too, but numpy/matplotlib
    # don't need them at runtime — only at build time).
    rm -rf "$PY_PREFIX/lib/python3.12/distutils" 2>/dev/null || true
    rm -rf "$PY_PREFIX/lib/python3.12/ensurepip" 2>/dev/null || true

    # ensurepip's wheels (bundled copies of pip + setuptools inside stdlib).
    rm -rf "$PY_PREFIX/lib/python3.12/site-packages/_distutils_hack" 2>/dev/null || true
fi

# ------------------------------------------------------------------
# 5. Codesign.
# Every .dylib / .so / executable in the tree needs the app's identity,
# hardened runtime, and entitlements (cs.allow-unsigned-executable-memory,
# cs.disable-library-validation, inherit) so the subprocess can load
# C-extension .so files that Apple didn't sign.
# ------------------------------------------------------------------
if [[ "${SKIP_SIGNING:-0}" == "1" ]]; then
    log "SKIP_SIGNING=1 — leaving binaries unsigned (sandbox launch WILL fail)"
else
    log "codesigning (identity: $SIGN_IDENTITY)"
    # Sign .so/.dylib first (leaves), then executables (roots).
    while IFS= read -r -d '' bin; do
        codesign --force --options=runtime --timestamp=none --sign "$SIGN_IDENTITY" "$bin" 2>/dev/null || true
    done < <(find "$PY_PREFIX" \( -name "*.so" -o -name "*.dylib" \) -type f -print0)

    while IFS= read -r -d '' bin; do
        codesign --force --options=runtime --timestamp=none --sign "$SIGN_IDENTITY" "$bin" 2>/dev/null || true
    done < <(find "$PY_PREFIX/bin" -type f -perm +111 -print0)
fi

# ------------------------------------------------------------------
# 6. Copy to OUTPUT_DIR.
# ------------------------------------------------------------------
if [[ "$OUTPUT_DIR" != "$PY_PREFIX" ]]; then
    log "copying → $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$(dirname "$OUTPUT_DIR")"
    cp -R "$PY_PREFIX" "$OUTPUT_DIR"
fi

# ------------------------------------------------------------------
# Done.
# ------------------------------------------------------------------
BYTES=$(du -sk "$OUTPUT_DIR" | awk '{print $1 * 1024}')
HUMAN=$(du -sh "$OUTPUT_DIR" | awk '{print $1}')
log "built bundle at $OUTPUT_DIR ($HUMAN / $BYTES bytes)"
log "interpreter: $OUTPUT_DIR/bin/python3"
