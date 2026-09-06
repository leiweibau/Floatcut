# Floatcut user guide

English | [Deutsch](bedienung.md) · [Project overview](../readme.md)

This guide describes Floatcut 4.0 for macOS. All screenshots use the English interface.

## Contents

- [First launch](#first-launch)
- [Clipboard menu](#clipboard-menu)
- [Favorites](#favorites)
- [Search and bezel](#search-and-bezel)
- [Settings](#settings)
- [Peer-to-peer synchronization](#peer-to-peer-synchronization)
- [Migration from Flycut](#migration-from-flycut)
- [Privacy and local data](#privacy-and-local-data)
- [Troubleshooting](#troubleshooting)
- [Keyboard reference](#keyboard-reference)

## First launch

Floatcut runs in the menu bar and does not open a conventional main window. Copy `Floatcut.app` to `/Applications`, start it, and look for the Floatcut icon at the right of the menu bar.

The app is locally or ad-hoc signed and is not notarized. If macOS blocks it, start it once and then choose **System Settings → Privacy & Security → Open Anyway**. Only bypass quarantine for a bundle you trust; never disable Gatekeeper globally.

Floatcut requests Accessibility permission so it can issue the paste command in the foreground application. Clipboard capture still works without that permission, but automatic paste may not. Synchronization additionally requires Local Network access.

## Clipboard menu

Click the menu bar icon to open the clipboard menu.

<p align="center">
  <img src="screenshots/clipboard-menu.png" alt="Floatcut clipboard menu with search, favorites and remote clip marker" width="432">
</p>

The newest clips appear at the top. Each text row shows a preview and, when enabled in **Appearance**, its source application and timestamp. Image rows use a thumbnail. Clicking the content selects it and—when **Menu selection pastes** is enabled—pastes it into the foreground application.

The controls have these functions:

- **Search field:** filters the current store while you type.
- **Star button beside Search:** opens Favorites. It becomes a clipboard button that returns to normal history. Switching stores never deletes anything.
- **Star on a normal history row:** adds that clip to Favorites and highlights the star. Clicking it again removes only the favorite copy.
- **Delete button on a favorite row:** removes the clip from Favorites while retaining it in normal history.
- **Clear All:** clears normal history but preserves Favorites.
- **Clear Favorites:** appears in Favorites and clears only that store.
- **Combine Texts:** adds a new clip containing every text entry in the active store in chronological order, separated by line breaks. Images are ignored and the source entries remain unchanged.

A subtle colored inner border identifies clips received through peer-to-peer sync. Its color and transparency are configurable and the border does not change row size.

Option-click the menu bar icon to pause or resume clipboard capture, for example before copying sensitive data.

## Favorites

Favorites are a separate persistent store. You can reach them using the star beside the menu search field or by pressing **F** while the bezel is open.

In normal history, the row star copies an item to Favorites without removing it from history. A highlighted star means that the item already exists in Favorites. Clicking it again removes the favorite copy. In Favorites, the row action is a delete icon; deleting there leaves or restores the corresponding item in normal history.

The maximum history and favorite counts are configured separately under **Settings → General**.

## Search and bezel

### Search window

Press **Shift-Command-B** by default. Start typing to filter the history, navigate with the arrow keys, and press Return to paste the selected result. The shortcut is configurable under **Hotkeys**.

### Bezel

Press **Shift-Command-V** by default to open the bezel: a compact overlay for keyboard-driven history access. Use the arrow keys or J/K to browse, then Return to paste. Press Escape to close without pasting.

When **Sticky bezel** is enabled, the overlay remains available after the activation keys are released. Space or a right-click can also pin it open. **Wraparound bezel** connects the newest and oldest ends of the list.

## Settings

Open **Settings** from the Floatcut menu or press **Command-,** while the bezel is active.

<p align="center">
  <img src="screenshots/preferences-general.png" alt="Floatcut General settings" width="760">
</p>

### General

**Behavior** controls sticky and wraparound bezel navigation, whether selecting a menu row immediately pastes, and whether Floatcut starts at login.

**Storage** sets the maximum numbers of recent clips and favorites, the number displayed in the menu, and when history is written to disk: never, on exit, or after each clip. The two folder selectors define where manual bezel saves and automatically preserved overflow items go.

**Capture** provides these safeguards and behaviors:

- **Remove duplicates:** avoids repeated copies in history.
- **Move pasted item to top:** treats a reused clip as the newest item.
- **Don't copy from password fields:** filters clipboard types used by password tools and secure fields.
- **Save forgotten clippings/favorites:** writes items displaced by the configured capacity to the selected folder.
- **Detect password-like content by length and character types:** skips values whose length is in the comma-separated list and which contain uppercase, lowercase, digit, and punctuation or symbol characters without whitespace. This is a heuristic, not a guarantee.

### Hotkeys

Change the global activation and search shortcuts, check Accessibility permission, and consult the in-app shortcut table. Choose combinations that do not conflict with macOS or another utility.

### Appearance

<p align="center">
  <img src="screenshots/preferences-appearance.png" alt="Floatcut Appearance settings" width="760">
</p>

Adjust bezel transparency, width, and height; show or hide source applications and timestamps; configure the color and transparency of the remote-clip border; and choose a menu bar icon variant. The interface language follows macOS language settings.

### Diagnostics

- **Record pasteboard types in clipboard history** adds the detected text pasteboard type as a diagnostic history item. It requires password-field filtering and should normally remain off.
- **Detailed sync logging** records redacted discovery, pairing, connection, transfer, and revocation diagnostics for troubleshooting.
- **Clear revocation list** removes locally retained revocation records. It does not recreate a pairing; pair again if the device should be trusted.

### Acknowledgements

This page lists the Jumpcut, Flycut, and Floatcut contributors and third-party components.

<p align="center">
  <img src="screenshots/about.png" alt="About Floatcut window" width="620">
</p>

## Peer-to-peer synchronization

Synchronization is optional and works directly over the local network. There is no central server, iCloud storage, account, offline queue, or history backfill. Only new supported clips are offered to paired devices that are online at copy time. A received clip is not forwarded again, which prevents loops.

### Enable and pair

1. Open **Settings → Synchronization** and enable local synchronization.
2. Choose a recognizable device name.
3. Enable synchronization on the other device and wait for discovery.
4. Start pairing from either device.
5. Compare the six-digit code shown on both devices. Confirm only when the codes match.
6. The peer appears in the paired-device list. Its status shows whether it is currently reachable.

macOS may ask for Local Network permission. Firewalls and filters such as Little Snitch must allow Floatcut's local discovery and connection traffic.

### Paired-device controls

- The enable switch controls sharing with that existing peer.
- The gear opens the outgoing image option for that peer. Turning **Send images to this device** off affects sending only; image reception remains active.
- **Unpair** removes trust and creates a revocation record. Clipboard history and Favorites are not deleted.
- **Allow new pairing requests** can reject all new requests while current pairings continue to work.

Text clips are synchronized through protocol V2. PNG and JPEG images can also be sent when the per-peer outgoing option is enabled. Image reception does not depend on that outgoing switch. Favorites state, full history, and deletion actions are not synchronized.

### Identity reset

The sync identity is stored in the macOS Keychain. A stable local signing identity lets updated local builds retain access. Ad-hoc signing or a changed designated requirement can make the existing identity inaccessible.

If Floatcut reports that the local sync identity is unavailable, use **Reset identity** in Synchronization. The warning disappears when reset succeeds. Resetting removes pairings and requires every device to pair again, but it does not delete clipboard history or Favorites.

## Migration from Flycut

When Floatcut detects supported data from an older Flycut/Floatcut installation, a migration entry appears in the Settings sidebar.

1. Quit the older application; do not run both apps during migration.
2. Open the migration page and run the check.
3. Start the manual migration.
4. Floatcut merges normal history and Favorites separately and imports supported preferences and shortcuts.
5. After verification, Floatcut restarts and reports success.

The source preference data remains unchanged. Floatcut does not remove the old application or its login item automatically; follow the displayed guidance and remove the old app manually when you have verified the result.

## Privacy and local data

History, Favorites, settings, pairing metadata, and revocations belong to the current macOS user. Floatcut 4.0 does not use iCloud synchronization. The sync private key and certificate live in that user's Keychain; peer metadata is kept in the user's Application Support area.

Every clipboard manager can observe highly sensitive content. Use password-field filtering, the password-like-value heuristic, and capture pause where appropriate. Pair only devices you control and compare pairing codes carefully. Detailed sync logs are designed to be redacted, but should still be reviewed before sharing.

## Troubleshooting

### Floatcut is blocked at first launch

Use **System Settings → Privacy & Security → Open Anyway**. For a trusted bundle, quarantine can alternatively be removed specifically from Floatcut:

```bash
xattr -dr com.apple.quarantine "/Applications/Floatcut.app"
```

[Sentinel](https://github.com/alienator88/Sentinel) can assist with trusted apps, although the project is in maintenance mode. Do not disable Gatekeeper globally.

### A selected clip is not pasted

Open **Settings → Hotkeys**, check Accessibility permission, and grant Floatcut access in **System Settings → Privacy & Security → Accessibility**. After replacing a locally built app, macOS may require permission again. Developers can reset the stale entry with:

```bash
tccutil reset Accessibility de.meierkarsten.floatcut
```

### A paired device is offline

Make sure both apps are running, synchronization is enabled, both devices are on a mutually reachable local network, and firewall or network-filter prompts have been approved. Floatcut does not queue clips for later delivery; copy the item again after the peer becomes online.

### Local sync identity is unavailable

First try a build signed with the same stable local identity. Otherwise select **Reset identity**, then pair the devices again. History and Favorites remain intact.

### Pairing stays pending

Approve macOS Local Network and firewall prompts on both devices, retry pairing, and verify that new pairing requests are allowed. Compare and confirm the same six-digit code on both sides. Enable detailed sync logging under **Diagnostics** if the problem persists.

## Keyboard reference

### Global and menu bar

| Shortcut | Action |
| --- | --- |
| Shift-Command-V | Open clipboard bezel |
| Shift-Command-B | Open clipboard search |
| Option-click menu icon | Pause or resume clipboard capture |

### Bezel navigation

| Key | Action |
| --- | --- |
| Up, Left, or K | Move to a newer item |
| Down, Right, or J | Move to an older item |
| Home | Jump to newest item |
| End | Jump to oldest item |
| Page Up / Page Down | Move ten items |
| 1–9, 0 | Jump to position; 0 means position 10 |
| Scroll wheel | Navigate history |

### Bezel actions

| Key | Action |
| --- | --- |
| Return | Paste selected item and close |
| Fn-Return | Move selected item to the top and close |
| Delete / Backspace | Delete selected item and close |
| Escape | Close without pasting |
| Double-click | Paste the item under the pointer |
| Command-, | Open Settings |
| S | Save the item to the configured folder |
| Shift-S | Save and remove the item |
| F | Switch between history and Favorites |
| Shift-F | Move the item to Favorites |
| Space or right-click | Pin the bezel open |
