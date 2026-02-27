# DiskSight Release Pipeline Setup

## 1. Prerequisites

- **Apple Developer account** with a Developer ID Application certificate (for code signing and notarization)
- **Xcode 15+** installed with command-line tools (`xcode-select --install`)
- **Sparkle framework** — included via SPM, no manual installation required

Verify your signing identity is available:

```bash
security find-identity -v -p codesigning
```

You should see a line containing `Developer ID Application: Your Name (TEAMID)`.

## 2. One-Time Setup

### Generate Sparkle EdDSA Keys

Sparkle uses EdDSA (Ed25519) signatures to verify update integrity. You need to generate a keypair once per project.

1. Locate the `generate_keys` tool in the Sparkle checkout:

   ```bash
   find build/SourcePackages/checkouts/Sparkle -name generate_keys
   ```

2. Run it:

   ```bash
   ./path/to/generate_keys
   ```

   This stores the **private key** in your macOS Keychain and prints the **public key** to stdout.

3. Copy the public key into `DiskSight/Info.plist` as the value for the `SUPublicEDKey` key, replacing `ED_KEY_PLACEHOLDER`:

   ```xml
   <key>SUPublicEDKey</key>
   <string>YOUR_PUBLIC_EDDSA_KEY_HERE</string>
   ```

> **Important:** The private key lives only in your Keychain. If you lose it, existing users cannot verify updates signed with a new key. Back up your Keychain or export the key securely.

### Configure Appcast Feed URL

Sparkle checks an appcast XML feed to discover new versions.

1. Host `appcast.xml` from the repository root. Options:
   - **GitHub raw URL:** `https://raw.githubusercontent.com/USERNAME/DiskSight/main/appcast.xml`
   - **GitHub Pages:** Configure Pages to serve from the repo root or a `docs/` folder

2. Update `DiskSight/Info.plist` with the feed URL, replacing `FEED_URL_PLACEHOLDER`:

   ```xml
   <key>SUFeedURL</key>
   <string>https://raw.githubusercontent.com/USERNAME/DiskSight/main/appcast.xml</string>
   ```

### Store Notarization Credentials

Apple notarization requires an app-specific password stored in your Keychain.

1. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com) under **Sign-In and Security > App-Specific Passwords**.

2. Store the credentials in your Keychain:

   ```bash
   xcrun notarytool store-credentials "DiskSight" \
     --apple-id "your@email.com" \
     --team-id "TEAMID" \
     --password "app-specific-password"
   ```

3. The release script uses the profile name `"DiskSight"` by default. To use a different profile name, set the `NOTARY_PROFILE` environment variable:

   ```bash
   export NOTARY_PROFILE="MyCustomProfile"
   ```

## 3. Release Process

1. **Update version numbers** in `project.pbxproj`:
   - `MARKETING_VERSION` (e.g., `1.2.0`) — the user-facing version string
   - `CURRENT_PROJECT_VERSION` (e.g., `12`) — the build number, must increment with each release

2. **Update `CHANGELOG.md`** with the new version's changes.

3. **Run the release script:**

   ```bash
   ./scripts/release.sh
   ```

   The script will:
   - Build a Release archive
   - Code sign with your Developer ID certificate
   - Create a DMG
   - Submit to Apple for notarization and staple the ticket
   - Generate the Sparkle appcast entry using `generate_appcast`

4. **Upload the DMG** to a GitHub Release tagged with the version (e.g., `v1.2.0`).

5. **Commit the updated `appcast.xml`** so Sparkle can discover the new version:

   ```bash
   git add appcast.xml
   git commit -m "Update appcast for v1.2.0"
   git push
   ```

## 4. Testing Updates Locally

### Skip Notarization

For faster local iteration, skip the notarization step:

```bash
./scripts/release.sh --skip-notarize
```

The resulting DMG will not be notarized and will trigger Gatekeeper warnings on other machines, but works fine on the build machine.

### Test the Sparkle Update Flow

To verify that Sparkle correctly detects and installs an update:

1. Serve the appcast locally:

   ```bash
   cd /path/to/DiskSight
   python3 -m http.server 8080
   ```

2. Temporarily change `SUFeedURL` in `Info.plist` to point to your local server:

   ```xml
   <key>SUFeedURL</key>
   <string>http://localhost:8080/appcast.xml</string>
   ```

3. Build and run the app with a lower version number than what is listed in `appcast.xml`. Sparkle should prompt to update.

4. Revert the `SUFeedURL` change before committing.

## 5. Troubleshooting

### Certificate Not Found

```
error: No signing certificate "Developer ID Application" found
```

- Verify your certificate is installed: `security find-identity -v -p codesigning`
- Ensure the certificate has not expired in the Apple Developer portal
- If recently installed, restart Xcode and try again

### Notarization Timeout or Failure

```
error: Failed to notarize
```

- Check the notarization log for details:

  ```bash
  xcrun notarytool log <submission-id> --keychain-profile "DiskSight"
  ```

- Common causes: unsigned nested frameworks, hardened runtime not enabled, restricted entitlements
- Ensure all binaries (including Sparkle) are signed with the `--options runtime` flag (hardened runtime)

### Sparkle Key Mismatch

If users see "Update signature is invalid" errors:

- The `SUPublicEDKey` in the running app does not match the private key used to sign the appcast
- This happens if you regenerated keys without updating `Info.plist`
- There is no recovery path for existing installs other than asking users to re-download the app manually

### Appcast Not Updating

- Verify the raw URL returns the latest XML (GitHub raw URLs can be cached for up to 5 minutes)
- Check that the `sparkle:version` in the appcast matches the new `CURRENT_PROJECT_VERSION`
- Ensure the DMG download URL in the appcast `<enclosure>` tag is publicly accessible
