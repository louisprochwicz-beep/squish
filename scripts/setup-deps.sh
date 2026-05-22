#!/usr/bin/env bash
# Squish — fetch build dependencies (Sparkle framework + cwebp helper)
# Run once on a fresh checkout. Vendored binaries are gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/vendor"

# --- Sparkle 2 (auto-update framework) -----------------------------------
if [ ! -d "$ROOT/vendor/Sparkle/Sparkle.framework" ]; then
    echo "→ Fetching latest Sparkle 2…"
    cd "$ROOT/vendor"
    LATEST=$(curl -sL "https://api.github.com/repos/sparkle-project/Sparkle/releases/latest" \
        | grep browser_download_url | grep '.tar.xz"' | head -1 \
        | sed 's/.*"\(https.*\)"/\1/')
    curl -L --progress-bar -o Sparkle.tar.xz "$LATEST"
    mkdir -p Sparkle
    tar -xf Sparkle.tar.xz -C Sparkle
    rm Sparkle.tar.xz
    echo "  ✓ Sparkle installed at vendor/Sparkle/"
else
    echo "→ Sparkle already present (skipping)"
fi

# --- cwebp helper (libwebp encoder) --------------------------------------
if [ ! -f "$ROOT/vendor/bin/cwebp" ]; then
    echo "→ Fetching libwebp/cwebp for macOS arm64…"
    cd /tmp
    curl -sL -o libwebp.tar.gz \
        "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0-mac-arm64.tar.gz"
    tar -xzf libwebp.tar.gz
    mkdir -p "$ROOT/vendor/bin"
    cp libwebp-*/bin/cwebp "$ROOT/vendor/bin/cwebp"
    rm -rf libwebp.tar.gz libwebp-*-mac-arm64
    chmod +x "$ROOT/vendor/bin/cwebp"
    echo "  ✓ cwebp installed at vendor/bin/cwebp"
else
    echo "→ cwebp already present (skipping)"
fi

echo
echo "✓ All build dependencies ready. You can now run ./build.sh"
