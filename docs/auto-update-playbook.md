# Auto-Update Playbook (Sparkle + GitHub Actions)

How Grey Eminence's auto-update system works, how it was set up, and how to release new versions.

## Architecture

```
App (Sparkle) → checks SUFeedURL → GitHub Releases/appcast.xml
             → downloads GreyEminence.dmg
             → verifies EdDSA signature (SUPublicEDKey)
             → installs update
```

- **Sparkle 2.x** handles the update UI, download, and installation
- **GitHub Actions** builds, signs, notarizes, and publishes releases
- **appcast.xml** is the update feed, hosted as a GitHub Release asset
- **EdDSA keys** verify update authenticity (private key signs, public key verifies)

## One-Time Setup (already done)

### 1. Generate Sparkle EdDSA Signing Keys

```bash
# Find Sparkle tools in DerivedData
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -path "*/Sparkle/bin/*" | head -1)

# Generate keys (stores private key in Keychain, prints public key)
$SPARKLE_BIN

# Export private key to a file (for GitHub secrets)
$SPARKLE_BIN -x /tmp/sparkle_private_key.pem
cat /tmp/sparkle_private_key.pem  # copy this for SPARKLE_PRIVATE_KEY secret
rm /tmp/sparkle_private_key.pem
```

### 2. Add Public Key to Info.plist

The public key goes in `GreyEminence/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>WcY3bO1Kn//JaSzIQ34jfsqE3wF1Z02qy4B5ar446NM=</string>
```

### 3. Set Feed URL in Info.plist

Points to the appcast.xml in the latest GitHub Release:

```xml
<key>SUFeedURL</key>
<string>https://github.com/mpurdon/greyeminence/releases/latest/download/appcast.xml</string>
```

### 4. Export Developer ID Certificate as .p12

1. Open **Keychain Access**
2. Find **"Developer ID Application: Matthew Purdon (YR87TCS6NH)"**
3. Expand it to see the private key underneath
4. Select both the certificate and key
5. Right-click → Export Items → save as `.p12` with a password
6. Base64 encode it:
   ```bash
   base64 -i ~/Documents/Developer\ ID\ Certificate.p12 | pbcopy
   ```

### 5. Add GitHub Repository Secrets

Six secrets required (Settings → Secrets and variables → Actions):

| Secret | Value | Source |
|--------|-------|--------|
| `APPLE_TEAM_ID` | `YR87TCS6NH` | developer.apple.com → Membership |
| `APPLE_ID` | Your Apple ID email | Your Apple account |
| `APPLE_APP_PASSWORD` | App-specific password | appleid.apple.com → Sign-In and Security → App-Specific Passwords |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key | Step 1 export |
| `DEVELOPER_ID_CERTIFICATE` | Base64-encoded .p12 | Step 4 |
| `DEVELOPER_ID_PASSWORD` | .p12 export password | Step 4 |

Set via CLI:
```bash
gh secret set APPLE_TEAM_ID
gh secret set APPLE_ID
gh secret set APPLE_APP_PASSWORD
gh secret set SPARKLE_PRIVATE_KEY < /tmp/sparkle_private_key.pem
base64 -i ~/Documents/Developer\ ID\ Certificate.p12 | gh secret set DEVELOPER_ID_CERTIFICATE
gh secret set DEVELOPER_ID_PASSWORD
```

Verify all are set:
```bash
gh secret list -R mpurdon/greyeminence
```

### 6. Create GitHub Actions Workflow

The workflow lives at `.github/workflows/release.yml` and does:

1. **Checkout** code
2. **XcodeGen** generates the Xcode project
3. **Restore entitlements** (XcodeGen wipes them)
4. **Import certificate** from secrets into a temporary keychain
5. **Build archive** with Developer ID signing + hardened runtime
6. **Export** the signed .app
7. **Notarize** with Apple (submit, wait, staple)
8. **Create DMG** with Applications symlink
9. **Sign DMG** with Sparkle EdDSA key
10. **Generate appcast.xml** with version, signature, download URL
11. **Create GitHub Release** with DMG and appcast as assets

## Releasing a New Version

### Step 1: Bump the version

In `project.yml`:
```yaml
MARKETING_VERSION: "0.8.0"       # User-facing version
CURRENT_PROJECT_VERSION: "13"     # Increment build number
```

### Step 2: Commit and push

```bash
git add project.yml
git commit -m "Bump version to 0.8.0"
git push
```

### Step 3: Tag and push

```bash
git tag v0.8.0
git push --tags
```

### Step 4: Watch the release

```bash
gh run list --limit 1                    # Find the run ID
gh run watch <run-id>                    # Watch live
# Or check: https://github.com/mpurdon/greyeminence/actions
```

### Step 5: Verify

```bash
gh release view v0.8.0                   # Check release assets
```

The release will appear at: `https://github.com/mpurdon/greyeminence/releases/tag/v0.8.0`

## Testing Updates Locally

To test the update flow without a real older version installed:

1. Change `MARKETING_VERSION` in `project.yml` to an older version (e.g., `"0.6.0"`)
2. Build and run from Xcode
3. Settings → General → Check for Updates
4. Sparkle should find the newer release and offer to update
5. Revert the version change after testing

## Troubleshooting

### "No update available" / "You're up to date"
- Your local build version matches or exceeds the latest release
- Check `SUFeedURL` in Info.plist is correct
- Verify appcast.xml exists at the feed URL

### Build fails: "No signing certificate found"
- The `DEVELOPER_ID_CERTIFICATE` secret is missing or malformed
- Re-export the .p12, base64 encode, and update the secret
- Make sure the certificate hasn't expired

### Notarization fails: "Invalid"
- Check the notarization log (the workflow fetches it automatically)
- Common causes: missing hardened runtime, unsigned embedded frameworks
- Ensure `ENABLE_HARDENED_RUNTIME=YES` is in the build step

### Notarization fails: authentication error
- `APPLE_APP_PASSWORD` may have expired — generate a new one
- `APPLE_ID` must match the account that owns the Developer ID

### Release creation fails: "Resource not accessible"
- The workflow needs `permissions: contents: write` (already configured)
- Check that GitHub Actions has write permissions in repo Settings → Actions → General

### Sparkle says "signature invalid"
- The `SUPublicEDKey` in Info.plist must match the private key used to sign
- If you regenerate keys, update both the Info.plist and the `SPARKLE_PRIVATE_KEY` secret

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/release.yml` | Release automation workflow |
| `GreyEminence/Info.plist` | Contains `SUFeedURL` and `SUPublicEDKey` |
| `project.yml` | Version numbers (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) |
| `GreyEminence/App/GreyEminenceApp.swift` | Sparkle `SPUStandardUpdaterController` setup |
| `GreyEminence/Features/Settings/GeneralSettingsView.swift` | "Check for Updates" button |

## Concurrency Notes

The CI runner uses Xcode 16.4 which has stricter Swift 6 concurrency checking than local development. If builds fail with "sending risks data races" errors, mark the offending properties with `nonisolated(unsafe)` or the class with `@unchecked Sendable`. See commits `826ae03` and `6ccf4ed` for examples.
