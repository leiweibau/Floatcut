# Floatcut release builds

Floatcut 4.0 is distributed as a locally signed macOS application. It does not
require Developer ID credentials and is not notarized. On a development Mac,
the packaging script uses the local identity `Floatcut Local Development` when
it is installed in the login keychain. Its stable designated requirement keeps
Keychain access consistent across rebuilt app bundles. The GitHub workflow,
which has no local certificate, creates an ad-hoc-signed DMG.

## Local app bundle

Build the app bundle in `dist/`:

```bash
bash Scripts/package-app.sh
```

The result is `dist/Floatcut.app`. The script builds the `Floatcut` scheme for
macOS and signs the complete bundle with `Floatcut Local Development` when that
identity is available. If it is absent, the script reports and uses an ad-hoc
signature. A specific identity can be selected with
`FLOATCUT_SIGNING_IDENTITY`; pass `-` explicitly to force ad-hoc signing.

The local certificate is intentionally not committed. It must be created once
per development Mac and retained in that user's login keychain. Deleting or
replacing it changes Floatcut's designated requirement and can make an existing
locally generated sync identity inaccessible.

## GitHub release

Push a version tag to trigger `.github/workflows/release.yml`:

```bash
git tag v4.0
git push origin v4.0
```

The workflow produces `Floatcut.dmg` with an Applications shortcut and
publishes it as a GitHub release. No certificate, provisioning profile or
notarization secret is used.

## Gatekeeper and accessibility

Because the app is not notarized, macOS can block its first launch. Start it
once and then choose **System Settings → Privacy & Security → Open Anyway**.
For a trusted bundle, the quarantine attribute can also be removed with:

```bash
xattr -dr com.apple.quarantine "/Applications/Floatcut.app"
```

[Sentinel](https://github.com/alienator88/Sentinel) is an optional helper for
handling trusted apps, but its project is currently in maintenance mode. Do
not disable Gatekeeper globally. If a rebuilt app cannot paste, reset and
re-grant its Accessibility permission:

```bash
tccutil reset Accessibility de.meierkarsten.floatcut
```
