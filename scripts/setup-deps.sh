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

# --- pngquant helper (TinyPNG-style lossy PNG compression) ---------------
# Built from source via cargo. No pre-built arm64 binary is officially
# distributed, so we compile once on first checkout (~30 seconds).
if [ ! -f "$ROOT/vendor/bin/pngquant" ]; then
    CARGO="$(command -v cargo || true)"
    if [ -z "$CARGO" ] && [ -x "$HOME/.cargo/bin/cargo" ]; then
        CARGO="$HOME/.cargo/bin/cargo"
    fi
    if [ -z "$CARGO" ]; then
        echo "✗ pngquant needs Rust to build, but cargo wasn't found."
        echo "  Install Rust (no sudo, no Homebrew) with:"
        echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path"
        echo "  Then re-run this script."
        echo
        echo "  Note: Squish will still build & run without pngquant — PNG"
        echo "  export will simply fall back to lossless encoding."
    else
        echo "→ Building pngquant from source (Rust)…"
        TMP_BUILD="/tmp/squish-pngquant-build-$$"
        rm -rf "$TMP_BUILD"
        git clone --depth 1 --recurse-submodules \
            https://github.com/kornelski/pngquant.git "$TMP_BUILD" >/dev/null 2>&1
        ( cd "$TMP_BUILD" && "$CARGO" build --release ) >/dev/null
        mkdir -p "$ROOT/vendor/bin"
        cp "$TMP_BUILD/target/release/pngquant" "$ROOT/vendor/bin/pngquant"
        chmod +x "$ROOT/vendor/bin/pngquant"
        rm -rf "$TMP_BUILD"
        echo "  ✓ pngquant installed at vendor/bin/pngquant"
    fi
else
    echo "→ pngquant already present (skipping)"
fi

echo
echo "✓ All build dependencies ready. You can now run ./build.sh"
