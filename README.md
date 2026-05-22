# Squish

Compress, convert and lightly edit images. Fast, native, beautiful on macOS.

<p align="center">
  <img src="Resources/squish-logo.svg" width="120" height="120" alt="Squish logo" />
</p>

## Download

**[⬇ Download the latest version](https://github.com/louisprochwicz-beep/squish/releases/latest/download/Squish.dmg)**

This link always points to the most recent release.

Requires macOS 14 (Sonoma) or later — Apple Silicon.

### First launch — Gatekeeper bypass

Squish is signed but not (yet) notarised through Apple's Developer Program, so the **first time** you open it macOS will say "Squish can't be opened because it is from an unidentified developer". This is normal:

1. Open Finder → **Applications**
2. **Right-click** (or `Ctrl`-click) on **Squish.app**
3. Choose **Open**
4. In the popup, click **Open** again

That's it — macOS whitelists the app permanently and never asks again. All subsequent launches (including future auto-updates) bypass Gatekeeper.

## Features

- **Compress** JPG, PNG, WEBP, HEIC with an inline quality slider
- **Convert** between formats — even WEBP, via a bundled `cwebp` helper (macOS's ImageIO doesn't encode WEBP natively)
- **Resize** by width or height (image ratio preserved), or **center-crop** to exact W×H when both dimensions are set
- **Quick edit**: rotate ±90°, flip horizontally, crop with rule-of-thirds guides and 8 resize handles
- **Batch import**: drag images, drag a whole folder (recursive), browse, or right-click → Open with → Squish
- **Live size estimate**: see the predicted output size update as you drag the quality slider
- **Native macOS look** — full dark / light mode, system blue accent, SF Symbols, system fonts
- **Auto-updates** via Sparkle (signed with EdDSA, no Apple Developer ID required)

## Updates

Squish checks for new releases automatically once a day. You can also force a check at any time:

- Menu → **Squish** → **Check for Updates…**, or
- Keyboard shortcut **⌘ U**, or
- The "More options" pill (•••) → **Auto-check for updates**

When a new version is available, a native Sparkle popup appears. Click **Install Update** — Squish verifies the EdDSA signature, swaps the app, and relaunches.

## Build from source

Requires Xcode Command Line Tools (no full Xcode app needed).

```bash
git clone https://github.com/louisprochwicz-beep/squish.git
cd squish
./scripts/setup-deps.sh   # fetch Sparkle + cwebp (gitignored)
./build.sh                # produces build/Squish.app + build/Squish.dmg
open build/Squish.app
```

The build is hermetic: it links against the macOS SDK plus the vendored Sparkle framework and `cwebp` binary. No Homebrew, no Swift Package Manager dependencies.

## Project layout

```
Sources/                 SwiftUI views + image processing
  Theme.swift            design tokens (colors, spacing, fonts, animations)
  ImageProcessor.swift   CoreImage + ImageIO + cwebp pipeline
  ...
Resources/               Info.plist, AppIcon.icns, SVG logo
docs/                    GitHub Pages site
  appcast.xml            Sparkle update feed
vendor/                  Build deps (gitignored, fetch via scripts/setup-deps.sh)
  Sparkle/               framework + signing tools
  bin/cwebp              libwebp encoder
build.sh                 → build/Squish.app + .dmg via swiftc + hdiutil
release.sh               → versioned + stable .dmg + signed appcast entry
scripts/setup-deps.sh    → re-download Sparkle and cwebp on a fresh checkout
```

See `RELEASING.md` for the full cut-a-release workflow.

## License

© 2026 Squish. All rights reserved.
