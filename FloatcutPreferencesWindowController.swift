import AppKit
import ServiceManagement
import SwiftUI

enum FloatcutRemoteClipBorderAppearance {
    static let defaultRed = 0.28
    static let defaultGreen = 0.62
    static let defaultBlue = 0.96
    static let defaultTransparency = 0.48

    static func color(red: Double, green: Double, blue: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    static func opacity(transparency: Double) -> Double {
        1 - min(max(transparency, 0), 1)
    }
}

/// Imports the local preferences of the pre-4.0 application without ever
/// modifying that application's preference domain.  The explicit destination
/// suite lets the migration UI be exercised before the bundle identifier has
/// been changed in a development build.
@objcMembers public final class FloatcutLegacyMigrationService: NSObject {
    public static let legacyBundleIdentifier = "com.generalarcade.flycut"
    public static let floatcutBundleIdentifier = "de.meierkarsten.floatcut"
    public static let migrationVersion = 1

    private static let migrationVersionKey = "floatcutPreferencesMigrationVersion"
    private static let migrationDismissedKey = "floatcutPreferencesMigrationDismissed"
    private static let pendingSuccessMessageKey = "floatcutPreferencesMigrationPendingSuccessMessage"
    fileprivate static let supportedKeys: Set<String> = [
        "ShortcutRecorder mainHotkey", "ShortcutRecorder searchHotkey",
        "displayNum", "displayLen", "menuIcon", "bezelAlpha", "bezelWidth", "bezelHeight",
        "stickyBezel", "wraparoundBezel", "popUpAnimation", "displayClippingSource",
        "menuSelectionPastes", "loadOnStartup", "savePreference", "rememberNum",
        "favoritesRememberNum", "skipPasswordFields", "skipPboardTypes", "skipPboardTypesList",
        "skipPasswordLengths", "skipPasswordLengthsList", "revealPasteboardTypes",
        "removeDuplicates", "pasteMovesToTop", "saveForgottenClippings",
        "saveForgottenFavorites", "saveToLocation", "autoSaveToLocation",
        "stifleRememberResizeWarning"
    ]

    private static let fileManager = FileManager.default
    private static let legacySandboxPreferencesPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Containers/com.generalarcade.flycut/Data/Library/Preferences/com.generalarcade.flycut.plist"
        )

    // The application's standard defaults are the new bundle-ID domain.  A
    // separate suite is not an application group and may be unavailable on
    // some macOS installations, so it must not be force-unwrapped here.
    private let destinationDefaults = UserDefaults.standard

    /// Objective-C bridge for the startup warning.
    public func isLegacyApplicationRunning() -> Bool {
        !legacyRunningApplications().isEmpty
    }

    /// Objective-C bridge for presenting the completion notice after restart.
    public func consumePendingSuccessMessage() -> String? {
        let message = destinationDefaults.string(forKey: Self.pendingSuccessMessageKey)
        if message != nil {
            destinationDefaults.removeObject(forKey: Self.pendingSuccessMessageKey)
            destinationDefaults.synchronize()
        }
        return message
    }

    fileprivate func inspect() -> LegacyMigrationInspection {
        let target = destinationDomain()
        let source = preferredSource()
        let legacyApps = legacyApplicationURLs()
        let runningApplications = legacyRunningApplications()
        let migrationCompleted = ((target[Self.migrationVersionKey] as? NSNumber)?.intValue ?? 0) >= Self.migrationVersion
        let dismissed = (target[Self.migrationDismissedKey] as? NSNumber)?.boolValue ?? false

        return LegacyMigrationInspection(
            source: source,
            legacyApplicationURLs: legacyApps,
            runningApplicationNames: runningApplications.compactMap(\.localizedName),
            migrationCompleted: migrationCompleted,
            dismissed: dismissed,
            destinationHasData: hasRelevantData(target)
        )
    }

    fileprivate func dismissMigrationNotice() {
        destinationDefaults.set(true, forKey: Self.migrationDismissedKey)
        destinationDefaults.synchronize()
    }

    fileprivate func performMigration() throws -> LegacyMigrationResult {
        if isLegacyApplicationRunning() {
            throw FloatcutLegacyMigrationError.legacyApplicationRunning
        }

        guard let source = preferredSource() else {
            throw FloatcutLegacyMigrationError.noReadableSource
        }

        guard PropertyListSerialization.propertyList(source.domain, isValidFor: .binary) else {
            throw FloatcutLegacyMigrationError.invalidSource
        }

        var target = destinationDomain()
        let sourceStore = source.domain["store"] as? [String: Any] ?? [:]
        let targetStore = target["store"] as? [String: Any] ?? [:]
        let mergedStore = mergeStore(source: sourceStore, target: targetStore, targetDomain: target, sourceDomain: source.domain)

        for key in Self.supportedKeys where target[key] == nil {
            if let value = source.domain[key] {
                target[key] = value
            }
        }
        if !mergedStore.isEmpty {
            target["store"] = mergedStore
        }

        let normalCount = clippingCount(in: mergedStore, key: "jcList")
        let favoriteCount = clippingCount(in: mergedStore, key: "favoritesList")
        let settingsCount = Self.supportedKeys.reduce(into: 0) { count, key in
            if source.domain[key] != nil { count += 1 }
        }
        let hotkeyCount = ["ShortcutRecorder mainHotkey", "ShortcutRecorder searchHotkey"].reduce(into: 0) { count, key in
            if source.domain[key] != nil { count += 1 }
        }

        target[Self.migrationVersionKey] = Self.migrationVersion
        target.removeValue(forKey: Self.migrationDismissedKey)
        let summary = "Die Daten der früheren Flycut-/Floatcut-Version wurden erfolgreich nach Floatcut übernommen. \(normalCount) Zwischenablageeinträge, \(favoriteCount) Favoriten und \(settingsCount) unterstützte Einstellungen wurden importiert. Die ursprünglichen Preferences bleiben als lokale Rückfallkopie erhalten. Sensible Clipboard-Inhalte können dadurch in beiden lokalen Preferences-Domains vorhanden sein. Flycut kann jetzt manuell entfernt werden."
        target[Self.pendingSuccessMessageKey] = summary

        guard PropertyListSerialization.propertyList(target, isValidFor: .binary) else {
            throw FloatcutLegacyMigrationError.invalidDestination
        }

        // setPersistentDomain writes a complete domain in one operation.  The
        // legacy source is deliberately never passed to set/remove APIs.
        destinationDefaults.setPersistentDomain(target, forName: Self.floatcutBundleIdentifier)
        destinationDefaults.synchronize()

        let writtenDomain = destinationDomain()
        guard (writtenDomain[Self.migrationVersionKey] as? NSNumber)?.intValue == Self.migrationVersion,
              clippingCount(in: writtenDomain["store"] as? [String: Any] ?? [:], key: "jcList") == normalCount,
              clippingCount(in: writtenDomain["store"] as? [String: Any] ?? [:], key: "favoritesList") == favoriteCount
        else {
            throw FloatcutLegacyMigrationError.writeVerificationFailed
        }

        return LegacyMigrationResult(
            normalClippingCount: normalCount,
            favoriteClippingCount: favoriteCount,
            settingsCount: settingsCount,
            hotkeyCount: hotkeyCount,
            sourceDescription: source.description
        )
    }

    private func destinationDomain() -> [String: Any] {
        destinationDefaults.persistentDomain(forName: Self.floatcutBundleIdentifier) ?? [:]
    }

    private func preferredSource() -> LegacyMigrationSource? {
        let legacyDefaults = UserDefaults.standard.persistentDomain(forName: Self.legacyBundleIdentifier) ?? [:]
        if hasRelevantData(legacyDefaults) {
            return LegacyMigrationSource(kind: .legacyDomain, domain: legacyDefaults)
        }

        guard Self.fileManager.fileExists(atPath: Self.legacySandboxPreferencesPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: Self.legacySandboxPreferencesPath)),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let sandboxDomain = propertyList as? [String: Any],
              hasRelevantData(sandboxDomain)
        else {
            return nil
        }
        return LegacyMigrationSource(kind: .sandboxDomain, domain: sandboxDomain)
    }

    private func hasRelevantData(_ domain: [String: Any]) -> Bool {
        if let store = domain["store"] as? [String: Any],
           clippingCount(in: store, key: "jcList") + clippingCount(in: store, key: "favoritesList") > 0 {
            return true
        }
        return Self.supportedKeys.contains { domain[$0] != nil }
    }

    private func legacyRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Self.legacyBundleIdentifier &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !$0.isTerminated
        }
    }

    private func legacyApplicationURLs() -> [URL] {
        var urls: Set<URL> = []
        if let launchServicesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.legacyBundleIdentifier) {
            urls.insert(launchServicesURL.standardizedFileURL)
        }

        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        ]
        for directory in applicationDirectories {
            for name in ["Flycut.app", "Floatcut.app"] {
                let candidate = directory.appendingPathComponent(name, isDirectory: true)
                if Bundle(url: candidate)?.bundleIdentifier == Self.legacyBundleIdentifier {
                    urls.insert(candidate.standardizedFileURL)
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func mergeStore(source: [String: Any], target: [String: Any], targetDomain: [String: Any], sourceDomain: [String: Any]) -> [String: Any] {
        var merged = target
        for (key, value) in source where merged[key] == nil {
            merged[key] = value
        }
        let primaryCapacity = capacity(for: "rememberNum", target: targetDomain, source: sourceDomain)
        let favoritesCapacity = capacity(for: "favoritesRememberNum", target: targetDomain, source: sourceDomain)
        merged["jcList"] = mergeClippings(
            target["jcList"] as? [[String: Any]] ?? [],
            source["jcList"] as? [[String: Any]] ?? [],
            capacity: primaryCapacity
        )
        merged["favoritesList"] = mergeClippings(
            target["favoritesList"] as? [[String: Any]] ?? [],
            source["favoritesList"] as? [[String: Any]] ?? [],
            capacity: favoritesCapacity
        )
        return merged
    }

    private func capacity(for key: String, target: [String: Any], source: [String: Any]) -> Int? {
        let value = (target[key] as? NSNumber)?.intValue ?? (source[key] as? NSNumber)?.intValue ?? 0
        return value > 0 ? value : nil
    }

    private func mergeClippings(_ target: [[String: Any]], _ source: [[String: Any]], capacity: Int?) -> [[String: Any]] {
        var seen = Set<String>()
        let merged = (target + source).filter { clipping in
            let key = clippingDeduplicationKey(clipping)
            return seen.insert(key).inserted
        }
        guard let capacity else { return merged }
        return Array(merged.prefix(capacity))
    }

    private func clippingDeduplicationKey(_ clipping: [String: Any]) -> String {
        if let identifier = clipping["Identifier"] as? String, !identifier.isEmpty {
            return "id:\(identifier)"
        }
        let image = (clipping["ImageData"] as? Data)?.base64EncodedString() ?? ""
        let contents = clipping["Contents"] as? String ?? ""
        let type = clipping["Type"] as? String ?? ""
        let appName = clipping["AppLocalizedName"] as? String ?? ""
        let appURL = clipping["AppBundleURL"] as? String ?? ""
        let timestamp = (clipping["Timestamp"] as? NSNumber)?.stringValue ?? ""
        return ["value", contents, image, type, appName, appURL, timestamp].joined(separator: "\u{1F}")
    }

    private func clippingCount(in store: [String: Any], key: String) -> Int {
        (store[key] as? [Any])?.count ?? 0
    }
}

private struct LegacyMigrationSource {
    enum Kind { case legacyDomain, sandboxDomain }
    let kind: Kind
    let domain: [String: Any]

    var description: String {
        switch kind {
        case .legacyDomain:
            return "~/Library/Preferences/com.generalarcade.flycut.plist"
        case .sandboxDomain:
            return "ehemaliger Flycut-Sandbox-Speicher"
        }
    }
}

private struct LegacyMigrationInspection {
    let source: LegacyMigrationSource?
    let legacyApplicationURLs: [URL]
    let runningApplicationNames: [String]
    let migrationCompleted: Bool
    let dismissed: Bool
    let destinationHasData: Bool

    var shouldShowMigration: Bool {
        !migrationCompleted && !dismissed && (source != nil || !legacyApplicationURLs.isEmpty)
    }

    var normalClippingCount: Int {
        (source?.domain["store"] as? [String: Any]).flatMap { ($0["jcList"] as? [Any])?.count } ?? 0
    }

    var favoriteClippingCount: Int {
        (source?.domain["store"] as? [String: Any]).flatMap { ($0["favoritesList"] as? [Any])?.count } ?? 0
    }

    var settingsCount: Int {
        guard let domain = source?.domain else { return 0 }
        return FloatcutLegacyMigrationService.supportedKeys.reduce(into: 0) { count, key in
            if domain[key] != nil { count += 1 }
        }
    }

    var hotkeyCount: Int {
        guard let domain = source?.domain else { return 0 }
        return ["ShortcutRecorder mainHotkey", "ShortcutRecorder searchHotkey"].reduce(into: 0) { count, key in
            if domain[key] != nil { count += 1 }
        }
    }
}

private struct LegacyMigrationResult {
    let normalClippingCount: Int
    let favoriteClippingCount: Int
    let settingsCount: Int
    let hotkeyCount: Int
    let sourceDescription: String

    var completionMessage: String {
        "Datenübernahme aus \(sourceDescription) vorbereitet: \(normalClippingCount) Zwischenablageeinträge, \(favoriteClippingCount) Favoriten, \(settingsCount) Einstellungen und \(hotkeyCount) Hotkeys. Floatcut wird jetzt neu gestartet und bestätigt die Migration nach dem erneuten Laden."
    }
}

private enum FloatcutLegacyMigrationError: LocalizedError {
    case legacyApplicationRunning
    case noReadableSource
    case invalidSource
    case invalidDestination
    case writeVerificationFailed

    var errorDescription: String? {
        switch self {
        case .legacyApplicationRunning:
            return "Eine frühere Flycut-/Floatcut-Version läuft noch. Bitte beende sie vor der Migration."
        case .noReadableSource:
            return "Es wurden keine lesbaren Daten einer früheren Flycut-/Floatcut-Version gefunden."
        case .invalidSource:
            return "Die gefundenen Daten konnten nicht sicher gelesen werden. Die ursprünglichen Preferences wurden nicht verändert."
        case .invalidDestination:
            return "Die Daten konnten nicht als gültige Floatcut-Preferences vorbereitet werden."
        case .writeVerificationFailed:
            return "Floatcut konnte die übernommene Preferences-Datei nicht verifizieren. Die ursprünglichen Preferences bleiben unverändert."
        }
    }
}

@objc public protocol FloatcutPreferencesWindowControllerDelegate: AnyObject {
    func preferencesWindowControllerDidRequestAccessibilityCheck(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowController(_ controller: FloatcutPreferencesWindowController, didRequestSelectSaveLocation autoSave: NSNumber)
    func preferencesWindowController(_ controller: FloatcutPreferencesWindowController, didChangeMainHotKeyKeyCode keyCode: NSNumber, modifierFlags: NSNumber)
    func preferencesWindowController(_ controller: FloatcutPreferencesWindowController, didChangeSearchHotKeyKeyCode keyCode: NSNumber, modifierFlags: NSNumber)
    func preferencesWindowController(_ controller: FloatcutPreferencesWindowController, didChangeRememberNum value: NSNumber)
    func preferencesWindowController(_ controller: FloatcutPreferencesWindowController, didChangeFavoritesRememberNum value: NSNumber)
    func preferencesWindowControllerDidChangeDisplayNum(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowControllerDidChangeBezelAppearance(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowControllerDidChangeMenuIcon(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowControllerDidChangeDisplaySource(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowControllerDidChangeLoadOnStartup(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowControllerDidChangeSavePreference(_ controller: FloatcutPreferencesWindowController)
    func preferencesWindowController(_ controller: FloatcutPreferencesWindowController, didCompleteLegacyMigration message: String)
    func preferencesWindowControllerDidRequestOpenLoginItems(_ controller: FloatcutPreferencesWindowController)
}

private enum PreferencesTab: String, CaseIterable, Identifiable {
    case general
    case hotkeys
    case appearance
    case synchronization
    case diagnostics
    case migration
    case acknowledgements

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .general:
            return "General"
        case .hotkeys:
            return "Hotkeys"
        case .appearance:
            return "Appearance"
        case .synchronization:
            return "Synchronisation"
        case .diagnostics:
            return "Diagnostics"
        case .migration:
            return "Flycut-/Floatcut-Migration"
        case .acknowledgements:
            return "Acknowledgements"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "slider.horizontal.3"
        case .hotkeys:
            return "keyboard"
        case .appearance:
            return "paintbrush"
        case .synchronization:
            return "network"
        case .diagnostics:
            return "stethoscope"
        case .migration:
            return "arrow.left.arrow.right"
        case .acknowledgements:
            return "text.document"
        }
    }
}

private struct HotKeyValue: Equatable {
    var keyCode: Int
    var modifierFlags: Int

    static let empty = HotKeyValue(keyCode: -1, modifierFlags: 0)
}

private struct ShortcutReference: Identifiable {
    let shortcutKey: LocalizedStringKey
    let actionKey: LocalizedStringKey

    var id: String { "\(String(describing: shortcutKey))-\(String(describing: actionKey))" }
}

private struct ShortcutReferenceSection: Identifiable {
    let title: LocalizedStringKey
    let entries: [ShortcutReference]

    var id: String { String(describing: title) }
}

private let inAppShortcutSections: [ShortcutReferenceSection] = [
    ShortcutReferenceSection(title: "Bezel Navigation", entries: [
        ShortcutReference(shortcutKey: "Up/Left Arrow or K", actionKey: "Move to newer item"),
        ShortcutReference(shortcutKey: "Down/Right Arrow or J", actionKey: "Move to older item"),
        ShortcutReference(shortcutKey: "Home", actionKey: "Jump to most recent item"),
        ShortcutReference(shortcutKey: "End", actionKey: "Jump to oldest item"),
        ShortcutReference(shortcutKey: "Page Up / Page Down", actionKey: "Move 10 items forward/back"),
        ShortcutReference(shortcutKey: "1-9, 0", actionKey: "Jump to position (0 = 10th)"),
        ShortcutReference(shortcutKey: "Scroll Wheel", actionKey: "Navigate history"),
    ]),
    ShortcutReferenceSection(title: "Bezel Actions", entries: [
        ShortcutReference(shortcutKey: "Return", actionKey: "Paste selected item"),
        ShortcutReference(shortcutKey: "Fn+Return", actionKey: "Move item to top of history"),
        ShortcutReference(shortcutKey: "Backspace/Delete", actionKey: "Delete selected item"),
        ShortcutReference(shortcutKey: "Escape", actionKey: "Close without pasting"),
        ShortcutReference(shortcutKey: "Double-Click", actionKey: "Paste item"),
        ShortcutReference(shortcutKey: "Command+,", actionKey: "Open preferences"),
        ShortcutReference(shortcutKey: "S", actionKey: "Save item to Desktop"),
        ShortcutReference(shortcutKey: "Shift+S", actionKey: "Save to Desktop and delete"),
        ShortcutReference(shortcutKey: "F", actionKey: "Toggle favorites store"),
        ShortcutReference(shortcutKey: "Shift+F", actionKey: "Move item to favorites"),
        ShortcutReference(shortcutKey: "Space", actionKey: "Pin bezel open (sticky mode)"),
        ShortcutReference(shortcutKey: "Right-Click", actionKey: "Pin bezel open (sticky mode)"),
    ]),
    ShortcutReferenceSection(title: "Menu Bar", entries: [
        ShortcutReference(shortcutKey: "Option+Click menu icon", actionKey: "Toggle clipboard tracking on/off"),
    ]),
]

private final class FloatcutPreferencesBridge: ObservableObject {
    weak var delegate: FloatcutPreferencesWindowControllerDelegate?

    @Published var selectedTab: PreferencesTab = .general
    @Published var mainHotKey: HotKeyValue = .empty
    @Published var searchHotKey: HotKeyValue = .empty
    @Published var saveToLocationTitle = NSLocalizedString("Choose Folder…", comment: "")
    @Published var autoSaveToLocationTitle = NSLocalizedString("Choose Folder…", comment: "")
    @Published var acknowledgementsText = ""
    @Published var migrationInspection = FloatcutLegacyMigrationService().inspect()
    @Published var migrationIsRunning = false
    @Published var migrationErrorMessage: String?

    func refreshDynamicContent() {
        mainHotKey = hotKeyValue(for: "ShortcutRecorder mainHotkey")
        searchHotKey = hotKeyValue(for: "ShortcutRecorder searchHotkey")
        saveToLocationTitle = titleForURL(defaultsKey: "saveToLocation")
        autoSaveToLocationTitle = titleForURL(defaultsKey: "autoSaveToLocation")
        acknowledgementsText = loadAcknowledgements()
        migrationInspection = FloatcutLegacyMigrationService().inspect()
        migrationErrorMessage = nil
    }

    func checkLegacyMigration() {
        migrationInspection = FloatcutLegacyMigrationService().inspect()
        migrationErrorMessage = nil
    }

    func dismissLegacyMigration() {
        FloatcutLegacyMigrationService().dismissMigrationNotice()
        migrationInspection = FloatcutLegacyMigrationService().inspect()
    }

    func performLegacyMigration(controller: FloatcutPreferencesWindowController) {
        migrationIsRunning = true
        migrationErrorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak controller] in
            do {
                let result = try FloatcutLegacyMigrationService().performMigration()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.migrationIsRunning = false
                    self.migrationInspection = FloatcutLegacyMigrationService().inspect()
                    if let controller {
                        self.delegate?.preferencesWindowController(controller, didCompleteLegacyMigration: result.completionMessage)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.migrationIsRunning = false
                    self.migrationErrorMessage = error.localizedDescription
                    self.migrationInspection = FloatcutLegacyMigrationService().inspect()
                }
            }
        }
    }

    func updateMainHotKey(_ value: HotKeyValue, controller: FloatcutPreferencesWindowController) {
        mainHotKey = value
        persistHotKey(value, key: "ShortcutRecorder mainHotkey")
        delegate?.preferencesWindowController(controller, didChangeMainHotKeyKeyCode: NSNumber(value: value.keyCode), modifierFlags: NSNumber(value: value.modifierFlags))
    }

    func updateSearchHotKey(_ value: HotKeyValue, controller: FloatcutPreferencesWindowController) {
        searchHotKey = value
        persistHotKey(value, key: "ShortcutRecorder searchHotkey")
        delegate?.preferencesWindowController(controller, didChangeSearchHotKeyKeyCode: NSNumber(value: value.keyCode), modifierFlags: NSNumber(value: value.modifierFlags))
    }

    private func hotKeyValue(for key: String) -> HotKeyValue {
        let defaults = UserDefaults.standard
        guard
            let dictionary = defaults.dictionary(forKey: key),
            let keyCode = dictionary["keyCode"] as? NSNumber,
            let modifierFlags = dictionary["modifierFlags"] as? NSNumber
        else {
            return .empty
        }

        return HotKeyValue(keyCode: keyCode.intValue, modifierFlags: modifierFlags.intValue)
    }

    private func persistHotKey(_ value: HotKeyValue, key: String) {
        UserDefaults.standard.set([
            "keyCode": NSNumber(value: value.keyCode),
            "modifierFlags": NSNumber(value: value.modifierFlags),
        ], forKey: key)
    }

    private func titleForURL(defaultsKey: String) -> String {
        if let url = UserDefaults.standard.url(forKey: defaultsKey) {
            return url.lastPathComponent
        }

        return NSLocalizedString("Choose Folder…", comment: "")
    }

    private func loadAcknowledgements() -> String {
        guard let fileRoot = Bundle.main.path(forResource: "acknowledgements", ofType: "txt") else {
            return NSLocalizedString("No acknowledgements found.", comment: "")
        }

        return (try? String(contentsOfFile: fileRoot, encoding: .utf8)) ?? NSLocalizedString("No acknowledgements found.", comment: "")
    }
}

private struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var value: HotKeyValue

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> SRRecorderControl {
        let recorder = SRRecorderControl(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        recorder.setCanCaptureGlobalHotKeys(true)
        recorder.setAllowsKeyOnly(false, escapeKeysRecord: false)
        recorder.setDelegate(context.coordinator)
        recorder.setKeyCombo(makeKeyCombo(from: value))
        return recorder
    }

    func updateNSView(_ nsView: SRRecorderControl, context: Context) {
        let combo = nsView.keyCombo()
        if Int(combo.code) != value.keyCode || Int(combo.flags) != value.modifierFlags {
            nsView.setKeyCombo(makeKeyCombo(from: value))
        }
    }

    private func makeKeyCombo(from value: HotKeyValue) -> KeyCombo {
        KeyCombo(flags: UInt(value.modifierFlags), code: value.keyCode)
    }

    final class Coordinator: NSObject {
        @Binding private var value: HotKeyValue

        init(value: Binding<HotKeyValue>) {
            _value = value
        }

        @objc override func shortcutRecorder(_ aRecorder: SRRecorderControl, keyComboDidChange newKeyCombo: KeyCombo) {
            value = HotKeyValue(keyCode: Int(newKeyCombo.code), modifierFlags: Int(newKeyCombo.flags))
        }

        @objc override func shortcutRecorder(_ aRecorder: SRRecorderControl, isKeyCode keyCode: Int, andFlagsTaken flags: UInt, reason: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
            false
        }
    }
}

private struct PreferenceSection<Content: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct PreferencesSidebarButton: View {
    let tab: PreferencesTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbolName)
                    .frame(width: 18)
                Text(tab.titleKey)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.001))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // The selected background is the sidebar's only selection indicator.
        // Do not retain AppKit's initial keyboard focus ring on the first row.
        .focusable(false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PreferencesDetailContainer<Content: View>: View {
    let tab: PreferencesTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tab.titleKey)
                    .font(.system(size: 24, weight: .semibold))
                Text(descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var descriptionText: LocalizedStringKey {
        switch tab {
        case .general:
            return "Clipboard behavior and retention"
        case .hotkeys:
            return "Keyboard shortcuts and accessibility"
        case .appearance:
            return "Bezel and menu presentation"
        case .synchronization:
            return "Direct, encrypted clipboard sharing in the local network"
        case .diagnostics:
            return "Troubleshooting for clipboard capture and local synchronization"
        case .migration:
            return "Import local data from an earlier Flycut or Floatcut version"
        case .acknowledgements:
            return "Credits and bundled open-source software"
        }
    }
}

private struct GeneralPreferencesView: View {
    weak var controller: FloatcutPreferencesWindowController?
    @ObservedObject var bridge: FloatcutPreferencesBridge

    @AppStorage("stickyBezel") private var stickyBezel = false
    @AppStorage("wraparoundBezel") private var wraparoundBezel = false
    @AppStorage("menuSelectionPastes") private var menuSelectionPastes = true
    @AppStorage("loadOnStartup") private var loadOnStartup = false
    @AppStorage("rememberNum") private var rememberNum = 40
    @AppStorage("favoritesRememberNum") private var favoritesRememberNum = 40
    @AppStorage("displayNum") private var displayNum = 10
    @AppStorage("savePreference") private var savePreference = 1
    @AppStorage("removeDuplicates") private var removeDuplicates = false
    @AppStorage("pasteMovesToTop") private var pasteMovesToTop = false
    @AppStorage("skipPasswordFields") private var skipPasswordFields = true
    @AppStorage("skipPasswordLengths") private var skipPasswordLengths = false
    @AppStorage("skipPasswordLengthsList") private var skipPasswordLengthsList = "12, 20, 32"
    @AppStorage("saveForgottenClippings") private var saveForgottenClippings = true
    @AppStorage("saveForgottenFavorites") private var saveForgottenFavorites = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferenceSection(titleKey: "Behavior") {
                    Toggle("Sticky bezel (bezel, or pop-up, stays visible after hotkey is released)", isOn: $stickyBezel)
                    Toggle("Wraparound bezel (the first and last items are adjacent in order)", isOn: $wraparoundBezel)
                    Toggle("Menu selection pastes", isOn: $menuSelectionPastes)
                    Toggle("Launch Floatcut on login", isOn: Binding(
                        get: { loadOnStartup },
                        set: { newValue in
                            loadOnStartup = newValue
                            if let controller {
                                bridge.delegate?.preferencesWindowControllerDidChangeLoadOnStartup(controller)
                            }
                        }
                    ))
                }

                PreferenceSection(titleKey: "Storage") {
                    Stepper(value: Binding(
                        get: { rememberNum },
                        set: { newValue in
                            rememberNum = max(1, newValue)
                            if let controller {
                                bridge.delegate?.preferencesWindowController(controller, didChangeRememberNum: NSNumber(value: rememberNum))
                            }
                            if displayNum > rememberNum {
                                displayNum = rememberNum
                                if let controller {
                                    bridge.delegate?.preferencesWindowControllerDidChangeDisplayNum(controller)
                                }
                            }
                        }
                    ), in: 1...500) {
                        Text("\(NSLocalizedString("Recent clippings to remember", comment: "")): \(rememberNum)")
                    }

                    Stepper(value: Binding(
                        get: { favoritesRememberNum },
                        set: { newValue in
                            favoritesRememberNum = max(1, newValue)
                            if let controller {
                                bridge.delegate?.preferencesWindowController(controller, didChangeFavoritesRememberNum: NSNumber(value: favoritesRememberNum))
                            }
                        }
                    ), in: 1...500) {
                        Text("\(NSLocalizedString("Favorite clippings to remember", comment: "")): \(favoritesRememberNum)")
                    }

                    Stepper(value: Binding(
                        get: { displayNum },
                        set: { newValue in
                            displayNum = min(max(1, newValue), rememberNum)
                            if let controller {
                                bridge.delegate?.preferencesWindowControllerDidChangeDisplayNum(controller)
                            }
                        }
                    ), in: 1...500) {
                        Text("\(NSLocalizedString("Display in menu", comment: "")): \(displayNum)")
                    }

                    Picker("Saving:", selection: Binding(
                        get: { savePreference },
                        set: { newValue in
                            savePreference = newValue
                            if let controller {
                                bridge.delegate?.preferencesWindowControllerDidChangeSavePreference(controller)
                            }
                        }
                    )) {
                        Text("Never").tag(0)
                        Text("On exit").tag(1)
                        Text("After each clip").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                PreferenceSection(titleKey: "Folders") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Save from bezel to:")
                            .font(.subheadline.weight(.medium))
                        HStack {
                            Button(bridge.saveToLocationTitle) {
                                if let controller {
                                    bridge.delegate?.preferencesWindowController(controller, didRequestSelectSaveLocation: 0)
                                }
                            }
                            Spacer()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Save forgotten items to:")
                            .font(.subheadline.weight(.medium))
                        HStack {
                            Button(bridge.autoSaveToLocationTitle) {
                                if let controller {
                                    bridge.delegate?.preferencesWindowController(controller, didRequestSelectSaveLocation: 1)
                                }
                            }
                            Spacer()
                        }
                    }
                }

                PreferenceSection(titleKey: "Capture") {
                    Toggle("Remove duplicates", isOn: $removeDuplicates)
                    Toggle("Move pasted item to top of stack", isOn: $pasteMovesToTop)
                    Toggle("Don't copy from password fields", isOn: $skipPasswordFields)
                    Toggle("Save forgotten clippings", isOn: $saveForgottenClippings)
                    Toggle("Save forgotten favorites", isOn: $saveForgottenFavorites)
                    Toggle("Detect with Upper, Lower, Digit, and Symbol lengths:", isOn: $skipPasswordLengths)

                    TextField(LocalizedStringKey("Ignored password lengths"), text: $skipPasswordLengthsList)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!skipPasswordLengths)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
    }
}

private struct HotkeyPreferencesView: View {
    weak var controller: FloatcutPreferencesWindowController?
    @ObservedObject var bridge: FloatcutPreferencesBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferenceSection(titleKey: "Hotkeys") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Activation shortcut")
                            .font(.subheadline.weight(.medium))
                        HotKeyRecorderView(value: Binding(
                            get: { bridge.mainHotKey },
                            set: { newValue in
                                if let controller {
                                    bridge.updateMainHotKey(newValue, controller: controller)
                                }
                            }
                        ))
                        .frame(width: 280, height: 26)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Search shortcut")
                            .font(.subheadline.weight(.medium))
                        HotKeyRecorderView(value: Binding(
                            get: { bridge.searchHotKey },
                            set: { newValue in
                                if let controller {
                                    bridge.updateSearchHotKey(newValue, controller: controller)
                                }
                            }
                        ))
                        .frame(width: 280, height: 26)
                    }
                }

                PreferenceSection(titleKey: "Accessibility") {
                    Button("Check Accessibility Permissions") {
                        if let controller {
                            bridge.delegate?.preferencesWindowControllerDidRequestAccessibilityCheck(controller)
                        }
                    }
                }

                PreferenceSection(titleKey: "Application Shortcuts") {
                    ForEach(inAppShortcutSections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))

                            ShortcutReferenceHeaderRow()

                            ForEach(section.entries) { entry in
                                ShortcutReferenceRow(entry: entry)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
    }
}

private struct ShortcutReferenceHeaderRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("Shortcut")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)

            Text("Action")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }
}

private struct ShortcutReferenceRow: View {
    let entry: ShortcutReference

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(entry.shortcutKey)
                .font(.system(.body, design: .monospaced))
                .frame(width: 220, alignment: .leading)

            Text(entry.actionKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct AppearancePreferencesView: View {
    weak var controller: FloatcutPreferencesWindowController?
    @AppStorage("bezelAlpha") private var bezelAlpha = 0.25
    @AppStorage("bezelWidth") private var bezelWidth = 500.0
    @AppStorage("bezelHeight") private var bezelHeight = 320.0
    @AppStorage("menuIcon") private var menuIcon = 0
    @AppStorage("displayClippingSource") private var displayClippingSource = true
    @AppStorage("remoteClipBorderRed") private var remoteClipBorderRed = FloatcutRemoteClipBorderAppearance.defaultRed
    @AppStorage("remoteClipBorderGreen") private var remoteClipBorderGreen = FloatcutRemoteClipBorderAppearance.defaultGreen
    @AppStorage("remoteClipBorderBlue") private var remoteClipBorderBlue = FloatcutRemoteClipBorderAppearance.defaultBlue
    @AppStorage("remoteClipBorderTransparency") private var remoteClipBorderTransparency = FloatcutRemoteClipBorderAppearance.defaultTransparency
    @ObservedObject var bridge: FloatcutPreferencesBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferenceSection(titleKey: "Bezel") {
                    HStack {
                        Text("Bezel transparency")
                        Spacer(minLength: 20)
                        Slider(value: Binding(
                            get: { bezelAlpha },
                            set: { newValue in
                                bezelAlpha = newValue
                                if let controller {
                                    bridge.delegate?.preferencesWindowControllerDidChangeBezelAppearance(controller)
                                }
                            }
                        ), in: 0.1...0.9)
                        .frame(width: 250)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Text("Bezel width")
                        Spacer(minLength: 20)
                        Slider(value: Binding(
                            get: { bezelWidth },
                            set: { newValue in
                                bezelWidth = newValue
                                if let controller {
                                    bridge.delegate?.preferencesWindowControllerDidChangeBezelAppearance(controller)
                                }
                            }
                        ), in: 200...1200)
                        .frame(width: 250)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Text("Bezel height")
                        Spacer(minLength: 20)
                        Slider(value: Binding(
                            get: { bezelHeight },
                            set: { newValue in
                                bezelHeight = newValue
                                if let controller {
                                    bridge.delegate?.preferencesWindowControllerDidChangeBezelAppearance(controller)
                                }
                            }
                        ), in: 180...900)
                        .frame(width: 250)
                    }
                    .frame(maxWidth: .infinity)

                    Toggle("Show clipping source app and time", isOn: Binding(
                        get: { displayClippingSource },
                        set: { newValue in
                            displayClippingSource = newValue
                            if let controller {
                                bridge.delegate?.preferencesWindowControllerDidChangeDisplaySource(controller)
                            }
                        }
                    ))
                }

                PreferenceSection(titleKey: "Synchronized clips") {
                    ColorPicker("Border color", selection: remoteClipBorderColor, supportsOpacity: false)

                    HStack {
                        Text("Border transparency")
                        Spacer(minLength: 20)
                        Text("\(Int((remoteClipBorderTransparency * 100).rounded())) %")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                        Slider(value: $remoteClipBorderTransparency, in: 0...0.9)
                            .frame(width: 250)
                    }
                    .frame(maxWidth: .infinity)

                    Text("Clips received through peer-to-peer synchronization are outlined in the menu and search lists. The border is drawn inside the row and does not change its size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PreferenceSection(titleKey: "Menu item icon") {
                    Picker("Menu item icon", selection: Binding(
                        get: { menuIcon },
                        set: { newValue in
                            menuIcon = newValue
                            if let controller {
                                bridge.delegate?.preferencesWindowControllerDidChangeMenuIcon(controller)
                            }
                        }
                    )) {
                        Text("Floatcut icon").tag(0)
                        Text("Black Floatcut icon").tag(1)
                        Text("White scissors").tag(2)
                        Text("Black scissors").tag(3)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
    }

    private var remoteClipBorderColor: Binding<Color> {
        Binding(
            get: {
                FloatcutRemoteClipBorderAppearance.color(
                    red: remoteClipBorderRed,
                    green: remoteClipBorderGreen,
                    blue: remoteClipBorderBlue
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                remoteClipBorderRed = Double(converted.redComponent)
                remoteClipBorderGreen = Double(converted.greenComponent)
                remoteClipBorderBlue = Double(converted.blueComponent)
            }
        )
    }
}

private struct SynchronizationPreferencesView: View {
    @ObservedObject private var sync = FloatcutSyncCoordinator.shared
    @State private var editedDeviceName = FloatcutSyncCoordinator.shared.deviceName
    @State private var peerToUnpair: FloatcutSyncPeer?
    @State private var confirmIdentityReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferenceSection(titleKey: "Local network sync") {
                    Toggle("Enable encrypted peer-to-peer clipboard sync", isOn: Binding(
                        get: { sync.isEnabled },
                        set: { sync.setEnabled($0) }
                    ))
                    Text("Only new text clips are sent directly to paired devices that are online. Floatcut does not use a cloud service and does not queue missed clips.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle("Allow new pairing requests", isOn: Binding(
                        get: { sync.allowsNewPairingRequests },
                        set: { sync.setAllowsNewPairingRequests($0) }
                    ))
                    Text("When disabled, Floatcut rejects incoming pairing requests. Existing paired devices remain connected and continue to synchronize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Device name", text: $editedDeviceName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { sync.deviceName = editedDeviceName }
                        Button("Apply") { sync.deviceName = editedDeviceName }
                    }
                    Text(sync.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !sync.localDeviceID.isEmpty {
                        Text("Device ID: \(sync.localDeviceID)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let warning = sync.securityWarning {
                    PreferenceSection(titleKey: "Security warning") {
                        Label(warning, systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if sync.identityResetRecommended {
                            Text("Local sync could not start because its cryptographic identity is incomplete or unavailable. Reset the sync identity to create a new one. All devices must then be paired again.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Dismiss") { sync.clearSecurityWarning() }
                            Spacer()
                            if sync.identityResetRecommended {
                                Button("Reset sync identity…", role: .destructive) { confirmIdentityReset = true }
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                PreferenceSection(titleKey: "Paired devices") {
                    if sync.pairedPeers.isEmpty {
                        Text("No devices have been paired.")
                            .foregroundStyle(.secondary)
                    }
                    if sync.pairedPeers.count >= 10 {
                        Label("The limit of ten paired devices has been reached.", systemImage: "person.3.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sync.pairedPeers) { peer in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle()
                                    .fill(sync.onlineDeviceIDs.contains(peer.deviceID) ? Color.green : Color.secondary.opacity(0.45))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name).font(.subheadline.weight(.semibold))
                                    Text("\(peer.platform) · \(sync.onlineDeviceIDs.contains(peer.deviceID) ? NSLocalizedString("Online", comment: "") : NSLocalizedString("Offline", comment: ""))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: NSLocalizedString("Last seen: %@", comment: ""), Self.lastSeen(peer.lastSeenMS)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 16) {
                                    Menu {
                                        Toggle("Send images to this device", isOn: Binding(
                                            get: { peer.allowsOutgoingImages },
                                            set: { sync.setOutgoingImagesAllowed(deviceID: peer.deviceID, allowed: $0) }
                                        ))
                                        Divider()
                                        Text("Receiving remains active")
                                    } label: {
                                        Image(systemName: "gearshape")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                    .help(Text(String(format: NSLocalizedString("Transfer settings for %@", comment: ""), peer.name)))
                                    .accessibilityLabel(Text(String(format: NSLocalizedString("Transfer settings for %@", comment: ""), peer.name)))
                                    Toggle("", isOn: Binding(
                                        get: { peer.enabled },
                                        set: { sync.setPeerEnabled(deviceID: peer.deviceID, enabled: $0) }
                                    ))
                                    .labelsHidden()
                                    .accessibilityLabel(Text(String(format: NSLocalizedString("Share with %@", comment: ""), peer.name)))
                                    Button("Unpair") { peerToUnpair = peer }
                                }
                            }
                            if peer.identityMismatch {
                                Label("Identity changed — connection blocked", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        if peer.id != sync.pairedPeers.last?.id { Divider() }
                    }
                }

                PreferenceSection(titleKey: "Available devices") {
                    let available = sync.discoveredPeers.filter { discovered in
                        !sync.pairedPeers.contains(where: { $0.deviceID == discovered.deviceID })
                    }
                    if available.isEmpty {
                        Text(sync.isEnabled ? "No unpaired compatible device is currently visible." : "Enable sync to search the local network.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(available) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.subheadline.weight(.semibold))
                                Text("\(device.platform) · protocol v\(device.protocolVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.protocolVersion != FloatcutSyncProtocol.version || device.capabilities != FloatcutSyncProtocol.capabilities {
                                Text("Incompatible").foregroundStyle(.secondary)
                            } else {
                                Button("Pair") { sync.pair(deviceID: device.deviceID) }
                                    .disabled(!device.allowsPairing || sync.pairedPeers.count >= 10)
                            }
                        }
                    }
                }

                if !sync.revocations.isEmpty {
                    PreferenceSection(titleKey: "Revocations") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(sync.revocations) { revocation in
                                GridRow {
                                    Text(String(revocation.peerDeviceID.prefix(8)))
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .gridColumnAlignment(.leading)
                                    Text(Self.revokedAt(revocation.revokedAtMS))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .gridColumnAlignment(.leading)
                                    Text(revocation.acknowledged ? "Unpaired · revocation confirmed" : "Unpaired · revocation delivery pending")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .gridColumnAlignment(.trailing)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                PreferenceSection(titleKey: "Sync identity") {
                    Text("Resetting creates a new cryptographic identity and removes every pairing. Clipboard history and favorites remain unchanged.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Reset sync identity…", role: .destructive) { confirmIdentityReset = true }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .onAppear { editedDeviceName = sync.deviceName }
        .alert("Unpair device?", isPresented: Binding(
            get: { peerToUnpair != nil },
            set: { if !$0 { peerToUnpair = nil } }
        ), presenting: peerToUnpair) { peer in
            Button("Unpair", role: .destructive) { sync.unpair(deviceID: peer.deviceID); peerToUnpair = nil }
            Button("Cancel", role: .cancel) { peerToUnpair = nil }
        } message: { peer in
            Text("Floatcut will immediately stop sharing with \(peer.name). Clipboard history is not deleted.")
        }
        .alert("Reset sync identity?", isPresented: $confirmIdentityReset) {
            Button("Reset", role: .destructive) { sync.resetIdentity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All devices must be paired again. Clipboard history and favorites are preserved.")
        }
    }

    private static func lastSeen(_ milliseconds: Int64) -> String {
        DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000),
            dateStyle: .short,
            timeStyle: .short
        )
    }

    private static func revokedAt(_ milliseconds: Int64) -> String {
        DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000),
            dateStyle: .short,
            timeStyle: .short
        )
    }
}

private struct DiagnosticsPreferencesView: View {
    @ObservedObject private var sync = FloatcutSyncCoordinator.shared
    @AppStorage("skipPasswordFields") private var skipPasswordFields = true
    @AppStorage("revealPasteboardTypes") private var revealPasteboardTypes = false
    @State private var confirmClearRevocations = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PreferenceSection(titleKey: "Clipboard diagnostics") {
                    Toggle("Include pasteboard types in clippings list", isOn: $revealPasteboardTypes)
                        .disabled(!skipPasswordFields)
                    Text("Adds the detected text pasteboard type as a diagnostic entry to the clipboard history. Password-field filtering must be enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PreferenceSection(titleKey: "Synchronization diagnostics") {
                    Toggle("Enable detailed sync diagnostics", isOn: Binding(
                        get: { sync.isDiagnosticLoggingEnabled },
                        set: { sync.setDiagnosticLoggingEnabled($0) }
                    ))
                    Text("Records redacted discovery, connection, pairing and revocation events. Clipboard contents, keys, nonces and verification codes are never written. Log file: \(sync.diagnosticLogPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Divider()
                    Button("Clear revocation list", role: .destructive) {
                        confirmClearRevocations = true
                    }
                    .disabled(sync.revocations.isEmpty)
                    Text("Permanently removes all stored revocation records. Existing pairings remain unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .alert("Clear revocation list?", isPresented: $confirmClearRevocations) {
            Button("Clear revocation list", role: .destructive) { sync.clearRevocations() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Previously revoked devices will still need to be paired again before they can reconnect.")
        }
    }
}

private struct AcknowledgementsPreferencesView: View {
    @ObservedObject var bridge: FloatcutPreferencesBridge

    var body: some View {
        ScrollView {
            Text(bridge.acknowledgementsText)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LegacyMigrationPreferencesView: View {
    weak var controller: FloatcutPreferencesWindowController?
    @ObservedObject var bridge: FloatcutPreferencesBridge

    private var inspection: LegacyMigrationInspection { bridge.migrationInspection }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !inspection.runningApplicationNames.isEmpty {
                    PreferenceSection(titleKey: "Frühere Version beenden") {
                        Label("Eine frühere Flycut-/Floatcut-Version läuft noch.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Bitte beende sie vor der Datenübernahme. Andernfalls können doppelte Zwischenablageeinträge und Hotkey-Konflikte entstehen.")
                            .foregroundStyle(.secondary)
                        Text(inspection.runningApplicationNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                PreferenceSection(titleKey: "Gefundene Daten") {
                    if let source = inspection.source {
                        LabeledContent("Quelle", value: source.description)
                        LabeledContent("Zwischenablageeinträge", value: "\(inspection.normalClippingCount)")
                        LabeledContent("Favoriten", value: "\(inspection.favoriteClippingCount)")
                        LabeledContent("Unterstützte Einstellungen", value: "\(inspection.settingsCount)")
                        LabeledContent("Hotkeys", value: "\(inspection.hotkeyCount)")
                    } else {
                        Text("Es wurden keine lesbaren alten Preferences gefunden. Eine ältere App-Installation allein enthält möglicherweise keine zu übernehmenden Daten.")
                            .foregroundStyle(.secondary)
                    }

                    if !inspection.legacyApplicationURLs.isEmpty {
                        Text("Installation einer früheren Flycut-/Floatcut-Version erkannt.")
                            .font(.subheadline.weight(.medium))
                            .padding(.top, 4)
                    }
                }

                PreferenceSection(titleKey: "Datenübernahme") {
                    Text("Die ursprünglichen Flycut-Preferences werden nicht verändert oder gelöscht. Bestehende Floatcut-Daten werden bevorzugt; Listen werden getrennt zusammengeführt und anhand stabiler Kennungen beziehungsweise Inhalt, Typ, Quelle und Zeitstempel dedupliziert.")
                        .foregroundStyle(.secondary)

                    if inspection.destinationHasData {
                        Label("Floatcut enthält bereits lokale Daten. Diese werden nicht überschrieben.", systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Migration prüfen") {
                            bridge.checkLegacyMigration()
                        }

                        Button(bridge.migrationIsRunning ? "Daten werden übernommen…" : "Daten nach Floatcut übernehmen") {
                            if let controller {
                                bridge.performLegacyMigration(controller: controller)
                            }
                        }
                        .disabled(bridge.migrationIsRunning || inspection.source == nil || !inspection.runningApplicationNames.isEmpty)
                    }

                    if let error = bridge.migrationErrorMessage {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PreferenceSection(titleKey: "Altes Anmeldeobjekt") {
                    Text("Floatcut verändert das Anmeldeobjekt der früheren Anwendung nicht. Deaktiviere es bei Bedarf manuell unter Systemeinstellungen > Allgemein > Anmeldeobjekte.")
                        .foregroundStyle(.secondary)
                    Button("Anmeldeobjekte öffnen") {
                        if let controller {
                            bridge.delegate?.preferencesWindowControllerDidRequestOpenLoginItems(controller)
                        }
                    }
                }

                PreferenceSection(titleKey: "Datenschutz") {
                    Text("Nach der Übernahme können sensible Zwischenablageinhalte sowohl in den alten Flycut-Preferences als auch in den neuen Floatcut-Preferences vorhanden sein. Die alte Datei bleibt absichtlich als lokale Rückfallkopie erhalten.")
                        .foregroundStyle(.secondary)
                }

                Button("Nicht mehr anzeigen") {
                    bridge.dismissLegacyMigration()
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
    }
}

private struct PreferencesWindowContentView: View {
    weak var controller: FloatcutPreferencesWindowController?
    @ObservedObject var bridge: FloatcutPreferencesBridge

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Floatcut")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                ForEach(visibleTabs) { tab in
                    PreferencesSidebarButton(tab: tab, isSelected: bridge.selectedTab == tab) {
                        bridge.selectedTab = tab
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            Group {
                switch bridge.selectedTab {
                case .general:
                    PreferencesDetailContainer(tab: .general) {
                        GeneralPreferencesView(controller: controller, bridge: bridge)
                    }
                case .hotkeys:
                    PreferencesDetailContainer(tab: .hotkeys) {
                        HotkeyPreferencesView(controller: controller, bridge: bridge)
                    }
                case .appearance:
                    PreferencesDetailContainer(tab: .appearance) {
                        AppearancePreferencesView(controller: controller, bridge: bridge)
                    }
                case .synchronization:
                    PreferencesDetailContainer(tab: .synchronization) {
                        SynchronizationPreferencesView()
                    }
                case .diagnostics:
                    PreferencesDetailContainer(tab: .diagnostics) {
                        DiagnosticsPreferencesView()
                    }
                case .migration:
                    PreferencesDetailContainer(tab: .migration) {
                        LegacyMigrationPreferencesView(controller: controller, bridge: bridge)
                    }
                case .acknowledgements:
                    PreferencesDetailContainer(tab: .acknowledgements) {
                        AcknowledgementsPreferencesView(bridge: bridge)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var visibleTabs: [PreferencesTab] {
        PreferencesTab.allCases.filter { tab in
            tab != .migration || bridge.migrationInspection.shouldShowMigration
        }
    }
}

@objcMembers public final class FloatcutPreferencesWindowController: NSWindowController {
    public weak var bridgeDelegate: FloatcutPreferencesWindowControllerDelegate? {
        didSet {
            bridge.delegate = bridgeDelegate
        }
    }

    private let bridge = FloatcutPreferencesBridge()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        bridge.refreshDynamicContent()

        let hostingView = NSHostingView(rootView: PreferencesWindowContentView(controller: self, bridge: bridge))
        window.contentView = hostingView
        window.title = NSLocalizedString("Preferences", comment: "")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 720)
        window.center()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showAndFocus() {
        bridge.refreshDynamicContent()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func refreshDynamicContent() {
        bridge.refreshDynamicContent()
    }
}
