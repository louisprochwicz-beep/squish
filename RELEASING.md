# Releasing Squish

This app uses **Sparkle 2** to deliver auto-updates without going through the Mac App Store.

## One-time setup

### 1. Pick a GitHub username/repo

You'll need a public GitHub repository (e.g. `yourname/squish`). It hosts:
- `docs/appcast.xml` → served via **GitHub Pages**
- Release `.dmg` files → uploaded to **GitHub Releases**

### 2. Replace placeholders

In `Resources/Info.plist` and `docs/appcast.xml`, replace **`YOUR_GITHUB_USERNAME`** with your actual GitHub handle. The feed URL will be:

```
https://YOUR_USERNAME.github.io/squish/appcast.xml
```

### 3. Push the repo + enable GitHub Pages

```bash
cd ~/Projects/Squish
git init
git add .gitignore Sources Resources docs build.sh release.sh README.md RELEASING.md
git commit -m "Initial Squish + Sparkle"
git branch -M main
git remote add origin git@github.com:YOUR_USERNAME/squish.git
git push -u origin main
```

Then on GitHub → **Settings → Pages** → Source: `main` branch, folder `/docs`. Your appcast becomes live at the URL above (takes ~30s).

### 4. Save your EdDSA private key safely

The private key lives in your macOS Keychain (item: `https://sparkle-project.org/Sparkle`, account: `ed25519`). **Back it up** to a password manager:

```bash
./vendor/Sparkle/bin/generate_keys -x backup-private-key.txt
# Move it OUT of the project folder — keep it in 1Password / Bitwarden / iCloud Keychain
```

If you ever lose it, every user has to manually re-download Squish since updates can no longer be verified.

> **Public key** (already in Info.plist):
> `WPkYgzAnlIQNP08sVKvjVI2c1KeYER5pZi8z9MxaHMU=`

---

## Cutting a release

```bash
./release.sh 1.1 "Added crop tool and dark mode"
```

This will:
1. Bump `CFBundleShortVersionString` and `CFBundleVersion` to `1.1` in Info.plist
2. Rebuild the `.app` and `.dmg`
3. Sign the DMG with EdDSA (your private key from Keychain)
4. Output `build/Squish-1.1.dmg` and `build/appcast-entry-1.1.xml`

Then:

```bash
# Upload to GitHub Releases
gh release create v1.1 build/Squish-1.1.dmg \
    --title "v1.1" \
    --notes "Added crop tool and dark mode"

# Insert the new <item> at the TOP of docs/appcast.xml
# (just below <language>en</language>)
open docs/appcast.xml build/appcast-entry-1.1.xml

# Commit + push
git add docs/appcast.xml Resources/Info.plist
git commit -m "Release 1.1"
git push
```

GitHub Pages re-serves `appcast.xml` within ~30s. Every running Squish checks the feed daily (or instantly via **Cmd-U** / "Check for Updates Now…"). When the EdDSA signature verifies, the user sees a native Sparkle popup, accepts, and the app auto-updates + relaunches.

---

## What users see

1. **First launch** of v1.0 (downloaded manually): macOS Gatekeeper asks for confirmation since the app is ad-hoc signed. After Right-click → Open → Open, it's whitelisted forever.
2. **Subsequent updates** (v1.1, v1.2…): Sparkle pops a native "A new version of Squish is available!" sheet with release notes. The user clicks "Install Update", Sparkle downloads the new DMG, verifies the EdDSA signature, swaps the bundle, and relaunches.

Because each new DMG is also ad-hoc signed, the Gatekeeper warning may reappear at the first launch of the *new* version on some macOS versions — Apple has tightened this over the years. The clean fix is to enroll in Apple Developer Program ($99/year) and notarize each release; see `RELEASING-NOTARIZED.md` (not included yet — ask Claude to add it later).

---

## Troubleshooting

**"Update is missing a DSA signature"**
The DMG wasn't signed with `sign_update`. Re-run `./release.sh`.

**"Failed to validate update signature"**
The DMG was modified after signing, or the public key in Info.plist of the *currently installed* app doesn't match the one used to sign. Don't change the EdDSA keypair after shipping v1.0.

**Feed not refreshing**
GitHub Pages caches aggressively. Sparkle adds a cache-buster, but if you want to test immediately: `curl -H "Cache-Control: no-cache" https://YOUR_USER.github.io/squish/appcast.xml`.

**Sparkle UI doesn't appear**
Make sure `Sparkle.framework` is inside `Squish.app/Contents/Frameworks/` and the rpath is set to `@executable_path/../Frameworks`. The `build.sh` handles both.
