# Floatcut release builds

Official releases must be signed with a **Developer ID Application** identity,
use the hardened runtime and a secure timestamp, pass Apple notarization, and
have the notarization tickets stapled to both the app and the DMG. The release
script fails rather than falling back to local or ad-hoc signing.

## Local Developer ID release

Prerequisites:

1. Install Xcode and select it, or set `DEVELOPER_DIR` to its `Contents/Developer` directory.
2. Import the Developer ID Application certificate **and its private key** into
   a Keychain available to `codesign`. Check with
   `security find-identity -v -p codesigning`. An `Apple Development` or
   `Developer ID Installer` certificate is not a substitute.
3. Store notary credentials in the Keychain. For an Apple ID and app-specific
   password, `notarytool` prompts securely when `--password` is omitted:

   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcrun notarytool store-credentials floatcut-release \
     --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   An App Store Connect API key can be used instead; keep its `.p8` file outside
   the repository:

   ```bash
   xcrun notarytool store-credentials floatcut-release \
     --key /private/path/AuthKey_KEYID.p8 \
     --key-id KEYID --issuer ISSUER_UUID
   ```

Build and notarize:

```bash
FLOATCUT_NOTARY_PROFILE=floatcut-release bash Scripts/package-notarized-app.sh
```

If multiple Developer ID Application identities are installed, specify the
exact name printed by `security find-identity -v -p codesigning` using
`FLOATCUT_DEVELOPER_ID_IDENTITY`. For a non-default Keychain profile, set
`FLOATCUT_NOTARY_KEYCHAIN` to that Keychain's path.

The script builds the universal Release app, signs it with Developer ID and
hardened runtime, checks the signature and timestamp, notarizes a ZIP of the
app, staples and assesses the app, then creates and signs a DMG, notarizes and
staples that DMG, and assesses it. Only after all checks succeed does it replace
`dist/Floatcut.app` and `dist/Floatcut_universal_<version>.dmg`. Keep both
artifacts together for release; the DMG contains the stapled app.

The notary log is printed for each submission. An Apple rejection or a missing
credential stops the build. Never commit the private certificate, `.p8` key,
app-specific password, or a Keychain to this repository.

## Local development builds

`bash Scripts/package-app.sh` remains available for local testing. It uses the
stable `Floatcut Local Development` signing identity if installed and otherwise
uses ad-hoc signing. Its output is **not notarized** and must not be published
as an official release. `FLOATCUT_SIGNING_IDENTITY` can select a different
local identity, but this script does not perform the release verification or
notarization steps.

## GitHub release workflow

The tag-triggered workflow uses the same notarized-release script and requires
these GitHub Actions secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `NOTARY_API_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| `NOTARY_API_KEY_ID` | App Store Connect API key ID |
| `NOTARY_API_ISSUER_ID` | App Store Connect API issuer UUID |

The workflow imports them into an ephemeral Keychain and fails if they are
absent. It verifies that a `v<version>` tag matches the app version. Because
GitHub and Gitea have **unrelated histories**, create a release tag only on a
GitHub-history commit. Do **not** push a tag from local Gitea `main` to GitHub;
that would upload the Gitea ancestry.

## First migration from local signing

Changing from `Floatcut Local Development` or ad-hoc signing to Developer ID
changes the app's designated requirement. macOS may ask again for Keychain,
Accessibility, or Local Network access. The existing sync identity should not
be reset automatically: first allow the Keychain request and check whether the
paired devices remain usable. If Keychain access cannot be recovered, use the
app's **Reset identity** control and pair devices again; history, favorites,
and preferences remain. If automatic paste fails, re-grant Accessibility in
System Settings. Only as a last resort, reset that permission with:

```bash
tccutil reset Accessibility de.meierkarsten.floatcut
```

An official notarized release should pass Gatekeeper without **Open Anyway**,
Sentinel, or removing quarantine. Those workarounds apply only to trusted
local, non-notarized builds. Do not disable Gatekeeper globally.
