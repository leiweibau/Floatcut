import AppKit
import Combine
import SwiftUI

/// Presentation only. The sync executor remains the authority for offers,
/// ownership, approval, progress and terminal results.
@objcMembers public final class FloatcutTransferPresentationCoordinator: NSObject, ObservableObject {
    public static let shared = FloatcutTransferPresentationCoordinator()

    @Published private(set) var targets: [FloatcutFileClientTarget] = []
    @Published private(set) var transfers: [FloatcutFileTransferSnapshot] = []

    private let sync = FloatcutSyncCoordinator.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var windows: [String: FloatcutTransferWindowController] = [:]
    private var snapshots: [String: FloatcutFileTransferSnapshot] = [:]
    private var sourcePanel: NSOpenPanel?
    private var sourceTarget: FloatcutFileClientTarget?
    private var sourceDelegate: FloatcutRegularFilePanelDelegate?

    private override init() { super.init() }

    public func startObserving() {
        precondition(Thread.isMainThread)
        guard subscriptions.isEmpty else { return }
        sync.$fileClientTargets.receive(on: RunLoop.main).sink { [weak self] targets in
            guard let self else { return }
            self.targets = targets
            if let target = self.sourceTarget, !self.selectionIsCurrent(target) {
                self.sourcePanel?.cancel(nil)
            }
        }.store(in: &subscriptions)
        sync.$fileTransfers.receive(on: RunLoop.main).sink { [weak self] snapshots in
            self?.apply(snapshots)
        }.store(in: &subscriptions)
    }

    func chooseFile(for target: FloatcutFileClientTarget) {
        precondition(Thread.isMainThread)
        startObserving()
        guard sourcePanel == nil, selectionIsCurrent(target) else { return }
        let panel = NSOpenPanel()
        panel.title = String(format: NSLocalizedString("Send file to %@", comment: ""), target.name)
        panel.prompt = NSLocalizedString("Send", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = false
        let delegate = FloatcutRegularFilePanelDelegate()
        panel.delegate = delegate
        sourcePanel = panel
        sourceTarget = target
        sourceDelegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        presentSourcePanel(panel, target: target, validator: delegate)
    }

    private func presentSourcePanel(_ panel: NSOpenPanel, target: FloatcutFileClientTarget,
                                    validator: FloatcutRegularFilePanelDelegate) {
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url, self.selectionIsCurrent(target) else {
                self.clearSourcePanel()
                return
            }
            do {
                // Repeat validation after the panel closes; the executor also
                // opens and validates the source before creating its snapshot.
                try validator.panel(panel, validate: url)
            } catch {
                panel.message = error.localizedDescription
                self.presentSourcePanel(panel, target: target, validator: validator)
                return
            }
            self.clearSourcePanel()
            self.sync.sendFile(url: url, peer: target)
        }
    }

    private func clearSourcePanel() {
        sourcePanel = nil
        sourceTarget = nil
        sourceDelegate = nil
    }

    private func selectionIsCurrent(_ target: FloatcutFileClientTarget) -> Bool {
        guard target.isAvailable, let context = target.context else { return false }
        return targets.contains { $0.id == target.id && $0.isAvailable && $0.context == context }
    }

    func reopen(_ id: String) {
        precondition(Thread.isMainThread)
        windows[id]?.showAndFocus()
    }

    private func apply(_ updates: [FloatcutFileTransferSnapshot]) {
        precondition(Thread.isMainThread)
        for snapshot in updates {
            if let previous = snapshots[snapshot.id] {
                guard FloatcutFileTransferPresentation.accepts(snapshot, after: previous) else { continue }
            }
            let isNew = snapshots[snapshot.id] == nil
            snapshots[snapshot.id] = snapshot
            if let controller = windows[snapshot.id] {
                controller.update(snapshot)
            } else {
                windows[snapshot.id] = FloatcutTransferWindowController(snapshot: snapshot, sync: sync)
            }
            if isNew && FloatcutFileTransferPresentation.shouldPresentNew(snapshot) {
                windows[snapshot.id]?.showAndFocus()
            }
        }

        // Retain a bounded recent history so closing the popover or a window
        // never loses the user's route back to an active transfer.
        let ordered = snapshots.values.sorted {
            if $0.phase.isTerminal != $1.phase.isTerminal { return !$0.phase.isTerminal }
            if $0.engineEpoch != $1.engineEpoch { return $0.engineEpoch > $1.engineEpoch }
            if $0.revision != $1.revision { return $0.revision > $1.revision }
            return $0.id < $1.id
        }
        let retained = Array(ordered.prefix(64))
        let retainedIDs = Set(retained.map(\.id))
        for id in Array(snapshots.keys) where !retainedIDs.contains(id) {
            windows.removeValue(forKey: id)?.window?.orderOut(nil)
            snapshots.removeValue(forKey: id)
        }
        transfers = retained
    }
}

final class FloatcutRegularFilePanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              values.isPackage != true else {
            throw NSError(domain: "FloatcutFileSelection", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Choose one regular file. Folders, packages and symbolic links cannot be sent.", comment: "")])
        }
    }
}

private final class FloatcutTransferWindowModel: ObservableObject {
    @Published var snapshot: FloatcutFileTransferSnapshot
    @Published var isChoosingDestination = false
    init(_ snapshot: FloatcutFileTransferSnapshot) { self.snapshot = snapshot }
}

/// The same window and content view serve both transfer directions.
final class FloatcutTransferWindowController: NSWindowController, NSWindowDelegate {
    private let model: FloatcutTransferWindowModel
    private let sync: FloatcutSyncCoordinator
    private var destinationPanel: NSOpenPanel?

    init(snapshot: FloatcutFileTransferSnapshot, sync: FloatcutSyncCoordinator) {
        model = FloatcutTransferWindowModel(snapshot)
        self.sync = sync
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 350),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = NSLocalizedString("File transfer", comment: "")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FloatcutTransferStatusView(
            model: model,
            accept: { [weak self] in self?.chooseDestination() },
            reject: { [weak self] in self?.reject() },
            cancel: { [weak self] in self?.cancel() },
            refresh: { [weak self] in self?.refresh() },
            close: { [weak self] in self?.window?.performClose(nil) }
        ))
        window.center()
        window.setFrameAutosaveName("FloatcutFileTransfer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ snapshot: FloatcutFileTransferSnapshot) {
        model.snapshot = snapshot
        if !snapshot.canAccept { destinationPanel?.cancel(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func chooseDestination() {
        let snapshot = model.snapshot
        guard snapshot.canAccept, destinationPanel == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose where to save the received file", comment: "")
        panel.message = String(format: NSLocalizedString("Save as: %@", comment: ""), snapshot.finalFileName)
        panel.prompt = NSLocalizedString("Accept and save", comment: "")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        destinationPanel = panel
        model.isChoosingDestination = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.destinationPanel = nil
            self.model.isChoosingDestination = false
            let current = self.model.snapshot
            guard response == .OK, let directory = panel.url,
                  FloatcutFileTransferPresentation.canApprove(current, selectedOffer: snapshot) else { return }
            // The executor rechecks the original offer deadline, ownership,
            // destination, capacity and receipt reservation before ACCEPT.
            self.sync.acceptFileTransfer(id: snapshot.id, directory: directory, revision: snapshot.revision, engineEpoch: snapshot.engineEpoch)
        }
    }

    private func reject() {
        let snapshot = model.snapshot
        guard snapshot.canAccept else { return }
        sync.rejectFileTransfer(id: snapshot.id, revision: snapshot.revision, engineEpoch: snapshot.engineEpoch)
    }

    private func cancel() {
        let snapshot = model.snapshot
        guard snapshot.canCancel else { return }
        sync.cancelFileTransfer(id: snapshot.id, revision: snapshot.revision, engineEpoch: snapshot.engineEpoch)
    }

    private func refresh() {
        let snapshot = model.snapshot
        guard snapshot.canRefreshStatus else { return }
        sync.refreshFileTransferStatus(id: snapshot.id)
    }
}

private struct FloatcutTransferStatusView: View {
    @ObservedObject var model: FloatcutTransferWindowModel
    let accept: () -> Void
    let reject: () -> Void
    let cancel: () -> Void
    let refresh: () -> Void
    let close: () -> Void

    private var snapshot: FloatcutFileTransferSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: snapshot.direction == .outgoing ? "arrow.up.doc" : "arrow.down.doc")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.fileName).font(.headline).lineLimit(2).textSelection(.enabled)
                    Text(String(format: NSLocalizedString(snapshot.direction == .outgoing ? "To: %@" : "From: %@", comment: ""), snapshot.peerName))
                        .foregroundStyle(.secondary)
                    Text(Self.byteCount(snapshot.byteSize)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(statusText).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)

            if snapshot.phase == .receiving || snapshot.phase == .committing || snapshot.phase == .saved {
                ProgressView(value: Double(snapshot.percentage), total: 100)
                    .accessibilityLabel(Text("Transfer progress"))
                    .accessibilityValue(Text(String(format: NSLocalizedString("%d percent received", comment: ""), snapshot.percentage)))
                Text(String(format: NSLocalizedString("%@ of %@ received · %d%%", comment: ""),
                            Self.byteCount(snapshot.receivedBytes), Self.byteCount(snapshot.byteSize), snapshot.percentage))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if !snapshot.phase.isTerminal && snapshot.phase != .offered {
                ProgressView().controlSize(.small)
            }

            if snapshot.canAccept {
                Text(String(format: NSLocalizedString("Save as: %@", comment: ""), snapshot.finalFileName))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            } else if snapshot.phase == .saved, snapshot.direction == .incoming,
                      let destination = snapshot.localDestination {
                Text(destination.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if snapshot.canAccept {
                    Button("Reject", role: .destructive, action: reject)
                    Spacer(minLength: 0)
                    Button("Accept and save…", action: accept)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isChoosingDestination)
                }
                if snapshot.canCancel {
                    if !snapshot.canAccept { Spacer(minLength: 0) }
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                } else if snapshot.phase == .committing {
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancel).disabled(true)
                } else if snapshot.phase.isTerminal {
                    if snapshot.canRefreshStatus { Button("Refresh status", action: refresh) }
                    Spacer(minLength: 0)
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 350)
    }

    private var statusText: String {
        let key: String
        switch snapshot.phase {
        case .preparing: key = "Preparing file…"
        case .offered:
            return snapshot.direction == .incoming
                ? NSLocalizedString("Approval required before the transfer can begin.", comment: "")
                : String(format: NSLocalizedString("Waiting for approval from %@…", comment: ""), snapshot.peerName)
        case .connecting: key = "Connecting…"
        case .receiving: key = snapshot.direction == .outgoing ? "Sending file…" : "Receiving file…"
        case .committing: key = "Saving and verifying file…"
        case .saved: key = snapshot.direction == .outgoing ? "The recipient confirmed the file was saved." : "File saved successfully."
        case .rejected: key = "Transfer rejected."
        case .cancelled: key = "Transfer cancelled."
        case .failed: key = "Transfer failed."
        case .unconfirmed: key = "Receipt has not been confirmed. Refresh the status to check again."
        }
        let status = NSLocalizedString(key, comment: "")
        guard let reason = snapshot.reason, snapshot.phase != .unconfirmed else { return status }
        return status + " " + FloatcutFileTransferPresentation.reason(reason)
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

enum FloatcutFileTransferPresentation {
    static func shouldPresentNew(_ snapshot: FloatcutFileTransferSnapshot) -> Bool {
        // Restored receiver receipts and outbound uncertainty are menu history.
        // An immediate local Send failure still needs its status window.
        !snapshot.phase.isTerminal || snapshot.direction == .outgoing && snapshot.phase != .unconfirmed
    }

    static func accepts(_ snapshot: FloatcutFileTransferSnapshot,
                        after previous: FloatcutFileTransferSnapshot) -> Bool {
        guard snapshot.id == previous.id, snapshot.peerDeviceID == previous.peerDeviceID,
              snapshot.direction == previous.direction,
              snapshot.engineEpoch >= previous.engineEpoch,
              snapshot.engineEpoch > previous.engineEpoch || snapshot.revision > previous.revision else { return false }
        if previous.phase == .unconfirmed {
            // Only an authoritative terminal status can resolve uncertainty.
            return snapshot.phase.isTerminal
        }
        if previous.phase.isTerminal { return snapshot.phase == previous.phase }
        return true
    }

    static func canApprove(_ current: FloatcutFileTransferSnapshot,
                           selectedOffer: FloatcutFileTransferSnapshot) -> Bool {
        current.canAccept && selectedOffer.canAccept
            && current.id == selectedOffer.id && current.peerDeviceID == selectedOffer.peerDeviceID
            && current.engineEpoch == selectedOffer.engineEpoch && current.revision == selectedOffer.revision
    }

    static func reason(_ value: String) -> String {
        let key: String
        switch value {
        case "offline": key = "Offline"
        case "disabled": key = "File transfers are disabled."
        case "sync_disabled": key = "Synchronisation is disabled."
        case "busy": key = "Another file transfer is in progress."
        case "unsupported": key = "This client does not support file transfers."
        case "identity_mismatch", "unauthorized": key = "The client identity could not be verified."
        case "user_rejected": key = "The recipient rejected the file."
        case "user_cancelled": key = "Cancelled by you."
        case "peer_cancelled": key = "Cancelled by the other client."
        case "revoked": key = "The device pairing was removed."
        case "timeout", "offer_timeout": key = "Approval was not received in time."
        case "data_timeout", "channel_timeout": key = "The transfer timed out."
        case "control_lost": key = "The connection to the client was lost."
        case "io_error": key = "The file could not be read or saved."
        case "size_mismatch", "hash_mismatch", "invalid_data", "data_error": key = "The received file failed verification."
        case "no_space": key = "There is not enough free space at the destination."
        case "too_large": key = "The file exceeds the 8 GiB transfer limit."
        case "invalid_source": key = "The selected source is no longer a regular file."
        case "unavailable": key = "The selected client is no longer available."
        case "destination_exists": key = "A file with this destination name already exists."
        case "unsupported_destination": key = "The selected folder does not support secure file saving."
        case "invalid_offer", "invalid_state": key = "The transfer request is no longer valid."
        default: key = "The file transfer could not be completed."
        }
        return NSLocalizedString(key, comment: "")
    }

    static func phase(_ snapshot: FloatcutFileTransferSnapshot) -> String {
        let key: String
        switch snapshot.phase {
        case .preparing: key = "Preparing"
        case .offered: key = snapshot.direction == .incoming ? "Approval required" : "Waiting for approval"
        case .connecting: key = "Connecting"
        case .receiving: return "\(snapshot.percentage)%"
        case .committing: key = "Saving"
        case .saved: key = "Saved"
        case .rejected: key = "Rejected"
        case .cancelled: key = "Cancelled"
        case .failed: key = "Failed"
        case .unconfirmed: key = "Unconfirmed"
        }
        return NSLocalizedString(key, comment: "")
    }
}
