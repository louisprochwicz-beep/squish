# Squish

A fast, minimalist native macOS app to compress, convert, resize and lightly edit images. Inspired by TinyPNG / Squoosh, but native AppKit/SwiftUI — no Electron, no web view.

## Features

- **Drag & drop** any number of images (JPG, PNG, WebP, HEIC, GIF, TIFF, BMP)
- **Compress** with a quality slider (0.1 → 1.0)
- **Convert** between JPEG · PNG · WebP · HEIC
- **Resize** by max dimension or percentage
- **Quick edit**: rotate, flip, crop (in a side sheet)
- **Strip metadata** (EXIF, GPS) for privacy
- **Batch export** to a folder with `-squish` suffix
- **Before → After** sizes per file + total savings pill

## Build

Requires Command Line Tools (no full Xcode needed) and macOS 14+.

```bash
cd ~/Projects/Squish
./build.sh
```

Produces:
- `build/Squish.app` — runnable bundle
- `build/Squish.dmg` — distributable disk image

## Run

```bash
open build/Squish.app
```

Or double-click `Squish.dmg`, drag `Squish.app` to `Applications`, then launch.

> Note: the build is **ad-hoc signed**. On first launch macOS Gatekeeper may say "not from an identified developer". Right-click the app → **Open** → **Open** to bypass once. For distribution, sign with a Developer ID and notarize (see below).

## Project structure

```
Squish/
├── Sources/
│   ├── SquishApp.swift        @main entry, Window scene
│   ├── ContentView.swift      Root layout, drop handling, processing pipeline
│   ├── DropZoneView.swift     Hero + compact drop zones
│   ├── ImageListView.swift    List of items with thumbnails / before-after
│   ├── ToolbarView.swift      Bottom bar: format, quality, resize, actions
│   ├── EditorSheet.swift      Rotate / flip / crop modal
│   ├── ImageProcessor.swift   CoreImage + ImageIO pipeline
│   ├── ImageItem.swift        Per-image model
│   ├── AppState.swift         Global state
│   └── Theme.swift            Colors, tokens, helpers
├── Resources/
│   └── Info.plist
├── build.sh                   swiftc + hdiutil build script
└── build/                     output (gitignore)
```

## Sign & notarize (for distribution)

```bash
# Replace with your team identity from Keychain
codesign --force --options runtime --deep \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  --entitlements entitlements.plist \
  build/Squish.app

xcrun notarytool submit build/Squish.dmg \
  --apple-id you@example.com --team-id TEAMID --password APP_PWD --wait

xcrun stapler staple build/Squish.dmg
```

## Roadmap ideas

- Add an `.icns` app icon (currently uses the default generic icon)
- Filters (CoreImage): brightness, contrast, saturation, vibrance
- Annotation tools (text, arrows, blur for redaction)
- Drop folders (recursive)
- Drag the processed image directly out of the app (NSItemProvider)
- AVIF encoding (requires libavif or macOS 15+)
- Preset profiles (Web, Email, Retina @2x, Instagram, etc.)
