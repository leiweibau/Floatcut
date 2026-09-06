import AppKit
import ImageIO
import SwiftUI

@objc public protocol FloatcutStatusPopoverControllerDelegate: AnyObject {
    func statusPopoverController(_ controller: FloatcutStatusPopoverController, didSelectStoreIndex storeIndex: NSNumber)
    func statusPopoverController(_ controller: FloatcutStatusPopoverController, searchTextDidChange searchText: String)
    func statusPopoverControllerDidRequestToggleStore(_ controller: FloatcutStatusPopoverController)
    func statusPopoverController(_ controller: FloatcutStatusPopoverController, didRequestActionForClippingIdentifier clippingIdentifier: String)
    func statusPopoverController(_ controller: FloatcutStatusPopoverController, didRequestClearFavorites clearFavorites: NSNumber)
    func statusPopoverControllerDidRequestMergeAll(_ controller: FloatcutStatusPopoverController)
    func statusPopoverControllerDidRequestPreferences(_ controller: FloatcutStatusPopoverController)
    func statusPopoverControllerDidRequestAbout(_ controller: FloatcutStatusPopoverController)
    func statusPopoverControllerDidRequestQuit(_ controller: FloatcutStatusPopoverController)
    func statusPopoverControllerDidClose(_ controller: FloatcutStatusPopoverController)
}

private struct StatusClipItem: Identifiable, Equatable {
    let id: String
    let storeIndex: Int
    let title: String
    let sourceName: String
    let dateText: String
    let isImage: Bool
    let isFavorite: Bool
    let isRemoteSync: Bool
    let previewData: Data?

    init(dictionary: NSDictionary, index: Int) {
        self.storeIndex = (dictionary["storeIndex"] as? NSNumber)?.intValue ?? index
        self.id = dictionary["clippingID"] as? String ?? "legacy-\(self.storeIndex)"
        self.title = dictionary["title"] as? String ?? ""
        self.sourceName = dictionary["sourceName"] as? String ?? ""
        self.dateText = dictionary["dateText"] as? String ?? ""
        self.isImage = (dictionary["isImage"] as? NSNumber)?.boolValue ?? false
        self.isFavorite = (dictionary["isFavorite"] as? NSNumber)?.boolValue ?? false
        self.isRemoteSync = (dictionary["isRemoteSync"] as? NSNumber)?.boolValue ?? false
        if let data = dictionary["previewData"] as? Data {
            self.previewData = data
        } else if let image = dictionary["previewImage"] as? NSImage {
            self.previewData = image.tiffRepresentation
        } else {
            self.previewData = nil
        }
    }

    static func == (lhs: StatusClipItem, rhs: StatusClipItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.storeIndex == rhs.storeIndex &&
        lhs.title == rhs.title &&
        lhs.sourceName == rhs.sourceName &&
        lhs.dateText == rhs.dateText &&
        lhs.isImage == rhs.isImage &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.isRemoteSync == rhs.isRemoteSync
    }
}

private final class FloatcutThumbnailLoader: ObservableObject {
    @Published var image: NSImage?

    private var requestedKey: NSString?

    func load(previewData: Data?, cacheKey: NSString, size: CGFloat) {
        requestedKey = cacheKey

        guard let previewData, !previewData.isEmpty else {
            image = nil
            return
        }

        image = FloatcutThumbnailService.shared.cachedImage(identifier: cacheKey as String, size: size, scale: 2)
        FloatcutThumbnailService.shared.request(data: previewData, identifier: cacheKey as String, size: size, scale: 2) { [weak self] image in
            guard let self, self.requestedKey == cacheKey else { return }
            self.image = image
        }
    }
}

private struct FloatcutStatusThumbnailView: View {
    let previewData: Data?
    let cacheKey: NSString
    let size: CGFloat

    @StateObject private var loader = FloatcutThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    Image(systemName: "photo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            loader.load(previewData: previewData, cacheKey: cacheKey, size: size)
        }
        .onChange(of: cacheKey as String) { _ in
            loader.load(previewData: previewData, cacheKey: cacheKey, size: size)
        }
    }
}

private final class FloatcutStatusPopoverViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [StatusClipItem] = []
    @Published var preferredHeight: CGFloat = 560
    @Published var scrollResetToken = 0
    @Published var arrowX: CGFloat = FloatcutStatusPopoverLayout.width / 2.0
    @Published var isFavoritesStoreActive = false
}

private enum FloatcutStatusPopoverLayout {
    static let width: CGFloat = 432
    static let preferredHeight: CGFloat = 560
    static let screenMargin: CGFloat = 18
    static let arrowHeight: CGFloat = 12
    static let arrowWidth: CGFloat = 28
    static let cornerRadius: CGFloat = 18
}

private struct FloatcutStatusClipRow: View {
    let item: StatusClipItem
    let isFavoritesStoreActive: Bool
    let activate: () -> Void
    let performItemAction: () -> Void

    @State private var hovered = false
    @State private var actionHovered = false
    @AppStorage("remoteClipBorderRed") private var remoteClipBorderRed = FloatcutRemoteClipBorderAppearance.defaultRed
    @AppStorage("remoteClipBorderGreen") private var remoteClipBorderGreen = FloatcutRemoteClipBorderAppearance.defaultGreen
    @AppStorage("remoteClipBorderBlue") private var remoteClipBorderBlue = FloatcutRemoteClipBorderAppearance.defaultBlue
    @AppStorage("remoteClipBorderTransparency") private var remoteClipBorderTransparency = FloatcutRemoteClipBorderAppearance.defaultTransparency

    var body: some View {
        HStack(spacing: 0) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    if item.isImage {
                        FloatcutStatusThumbnailView(
                            previewData: item.previewData,
                            cacheKey: "\(item.id)-34" as NSString,
                            size: 34
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .italic(item.isImage)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !metadata.isEmpty {
                            Text(metadata)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: performItemAction) {
                Image(systemName: actionSymbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(actionForegroundStyle)
                    .frame(width: 30, height: 30)
                    .background(actionBackgroundView)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 44)
            .frame(minHeight: 52)
            .help(actionHelp)
            .accessibilityLabel(Text(actionLabelKey))
            .onHover { hovered in
                actionHovered = hovered
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(backgroundView)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipped()
        .onHover { hovered in
            self.hovered = hovered
        }
    }

    private var metadata: String {
        [item.sourceName, item.dateText]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(hovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.16 : 0.06), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(remoteSyncBorderColor, lineWidth: 1)
            )
    }

    private var remoteSyncBorderColor: Color {
        guard item.isRemoteSync else { return .clear }
        return FloatcutRemoteClipBorderAppearance.color(
            red: remoteClipBorderRed,
            green: remoteClipBorderGreen,
            blue: remoteClipBorderBlue
        )
        .opacity(FloatcutRemoteClipBorderAppearance.opacity(transparency: remoteClipBorderTransparency))
    }

    private var actionSymbolName: String {
        if isFavoritesStoreActive {
            return "trash"
        }
        return item.isFavorite ? "star.fill" : "star"
    }

    private var actionForegroundStyle: Color {
        if isFavoritesStoreActive {
            return .red.opacity(0.9)
        }
        return item.isFavorite ? .yellow : .secondary
    }

    private var actionBackgroundView: some View {
        Circle()
            .fill(actionBackgroundColor)
    }

    private var actionBackgroundColor: Color {
        if actionHovered {
            return Color.primary.opacity(0.12)
        }
        if !isFavoritesStoreActive && item.isFavorite {
            return Color.yellow.opacity(0.14)
        }
        return .clear
    }

    private var actionLabelKey: LocalizedStringKey {
        if isFavoritesStoreActive {
            return LocalizedStringKey("Move to Clipboard")
        }
        return item.isFavorite
            ? LocalizedStringKey("Remove from Favorites")
            : LocalizedStringKey("Add to Favorites")
    }

    private var actionHelp: String {
        if isFavoritesStoreActive {
            return NSLocalizedString("Move to Clipboard", comment: "")
        }
        return NSLocalizedString(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", comment: "")
    }
}

private struct FloatcutStatusFooterButton: View {
    let titleKey: LocalizedStringKey
    let role: ButtonRole?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(role: role, action: action) {
            ZStack {
                backgroundView

                Text(titleKey)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .foregroundStyle(foregroundStyle)
        .onHover { hovered in
            self.hovered = hovered
        }
    }

    private var foregroundStyle: Color {
        role == .destructive ? .red.opacity(0.9) : .primary
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.06), lineWidth: 1)
            )
    }
}

private struct FloatcutStatusPopoverContentView: View {
    @ObservedObject var model: FloatcutStatusPopoverViewModel
    let activate: (Int) -> Void
    let performItemAction: (String) -> Void
    let toggleStore: () -> Void
    let clearAll: () -> Void
    let mergeAll: () -> Void
    let preferences: () -> Void
    let about: () -> Void
    let quit: () -> Void
    let searchChanged: (String) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField(LocalizedStringKey("Search"), text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)

                    Button(action: toggleStore) {
                        Image(systemName: model.isFavoritesStoreActive ? "doc.on.clipboard" : "star")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(storeToggleHelp)
                    .accessibilityLabel(Text(storeToggleLabelKey))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear
                            .frame(height: 0)
                            .id("top-anchor")

                        if model.items.isEmpty {
                            Text(LocalizedStringKey("Empty"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ForEach(model.items) { item in
                                FloatcutStatusClipRow(
                                    item: item,
                                    isFavoritesStoreActive: model.isFavoritesStoreActive,
                                    activate: { activate(item.storeIndex) },
                                    performItemAction: { performItemAction(item.id) }
                                )
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .onAppear {
                    scrollToTop(using: proxy)
                }
                .onChange(of: model.scrollResetToken) { _ in
                    scrollToTop(using: proxy)
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    FloatcutStatusFooterButton(
                        titleKey: model.isFavoritesStoreActive ? LocalizedStringKey("Clear Favorites") : LocalizedStringKey("Clear All"),
                        role: .destructive,
                        action: clearAll
                    )
                    FloatcutStatusFooterButton(titleKey: LocalizedStringKey("Combine Texts"), role: nil, action: mergeAll)
                }

                HStack(spacing: 8) {
                    FloatcutStatusFooterButton(titleKey: LocalizedStringKey("Preferences"), role: nil, action: preferences)
                    FloatcutStatusFooterButton(titleKey: LocalizedStringKey("About Floatcut"), role: nil, action: about)
                    FloatcutStatusFooterButton(titleKey: LocalizedStringKey("Quit"), role: nil, action: quit)
                }
            }
            .padding(12)
        }
        .frame(width: FloatcutStatusPopoverLayout.width)
        .frame(height: model.preferredHeight)
        .background(.regularMaterial)
        .clipped()
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: model.searchText) { newValue in
            searchChanged(newValue)
        }
    }

    private func scrollToTop(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("top-anchor", anchor: .top)
        }
    }

    private var storeToggleLabelKey: LocalizedStringKey {
        model.isFavoritesStoreActive ? LocalizedStringKey("Show Clipboard") : LocalizedStringKey("Show Favorites")
    }

    private var storeToggleHelp: String {
        NSLocalizedString(model.isFavoritesStoreActive ? "Show Clipboard" : "Show Favorites", comment: "")
    }
}

private struct FloatcutStatusPopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FloatcutStatusPopoverPanelView: View {
    @ObservedObject var model: FloatcutStatusPopoverViewModel
    let activate: (Int) -> Void
    let performItemAction: (String) -> Void
    let toggleStore: () -> Void
    let clearAll: () -> Void
    let mergeAll: () -> Void
    let preferences: () -> Void
    let about: () -> Void
    let quit: () -> Void
    let searchChanged: (String) -> Void

    var body: some View {
        VStack(spacing: -1) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: arrowLeading)

                FloatcutStatusPopoverArrow()
                    .fill(.regularMaterial)
                    .frame(width: FloatcutStatusPopoverLayout.arrowWidth, height: FloatcutStatusPopoverLayout.arrowHeight)

                Spacer(minLength: 0)
            }
            .frame(width: FloatcutStatusPopoverLayout.width, height: FloatcutStatusPopoverLayout.arrowHeight, alignment: .leading)

            FloatcutStatusPopoverContentView(
                model: model,
                activate: activate,
                performItemAction: performItemAction,
                toggleStore: toggleStore,
                clearAll: clearAll,
                mergeAll: mergeAll,
                preferences: preferences,
                about: about,
                quit: quit,
                searchChanged: searchChanged
            )
            .clipShape(RoundedRectangle(cornerRadius: FloatcutStatusPopoverLayout.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FloatcutStatusPopoverLayout.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(width: FloatcutStatusPopoverLayout.width, height: model.preferredHeight + FloatcutStatusPopoverLayout.arrowHeight)
    }

    private var arrowLeading: CGFloat {
        min(
            max(0, model.arrowX - (FloatcutStatusPopoverLayout.arrowWidth / 2.0)),
            FloatcutStatusPopoverLayout.width - FloatcutStatusPopoverLayout.arrowWidth
        )
    }
}

private final class FloatcutStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@objcMembers public final class FloatcutStatusPopoverController: NSObject {
    public weak var bridgeDelegate: FloatcutStatusPopoverControllerDelegate?

    private let viewModel = FloatcutStatusPopoverViewModel()
    private let hostingController: NSHostingController<FloatcutStatusPopoverPanelView>
    private var panel: NSPanel?
    private weak var positioningWindow: NSWindow?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    public override init() {
        self.hostingController = NSHostingController(
            rootView: FloatcutStatusPopoverPanelView(
                model: viewModel,
                activate: { _ in },
                performItemAction: { _ in },
                toggleStore: {},
                clearAll: {},
                mergeAll: {},
                preferences: {},
                about: {},
                quit: {},
                searchChanged: { _ in }
            )
        )

        super.init()

        self.hostingController.rootView = FloatcutStatusPopoverPanelView(
            model: viewModel,
            activate: { [weak self] storeIndex in
                guard let self else { return }
                self.closePopover()
                self.bridgeDelegate?.statusPopoverController(self, didSelectStoreIndex: NSNumber(value: storeIndex))
            },
            performItemAction: { [weak self] clippingIdentifier in
                guard let self else { return }
                self.bridgeDelegate?.statusPopoverController(
                    self,
                    didRequestActionForClippingIdentifier: clippingIdentifier
                )
            },
            toggleStore: { [weak self] in
                guard let self else { return }
                self.bridgeDelegate?.statusPopoverControllerDidRequestToggleStore(self)
            },
            clearAll: { [weak self] in
                guard let self else { return }
                self.bridgeDelegate?.statusPopoverController(
                    self,
                    didRequestClearFavorites: NSNumber(value: self.viewModel.isFavoritesStoreActive)
                )
            },
            mergeAll: { [weak self] in
                guard let self else { return }
                self.closePopover()
                self.bridgeDelegate?.statusPopoverControllerDidRequestMergeAll(self)
            },
            preferences: { [weak self] in
                guard let self else { return }
                self.closePopover()
                self.bridgeDelegate?.statusPopoverControllerDidRequestPreferences(self)
            },
            about: { [weak self] in
                guard let self else { return }
                // Do not tear down the SwiftUI hosting view while its button
                // gesture is still being processed.  On recent macOS releases
                // that can leave AppKit with an invalid unowned gesture target.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.closePopover()
                    self.bridgeDelegate?.statusPopoverControllerDidRequestAbout(self)
                }
            },
            quit: { [weak self] in
                guard let self else { return }
                self.closePopover()
                self.bridgeDelegate?.statusPopoverControllerDidRequestQuit(self)
            },
            searchChanged: { [weak self] searchText in
                guard let self else { return }
                self.bridgeDelegate?.statusPopoverController(self, searchTextDidChange: searchText)
            }
        )

        applyContentSize(NSSize(width: FloatcutStatusPopoverLayout.width, height: viewModel.preferredHeight))
    }

    deinit {
        stopMonitoringEvents()
    }

    public var isShown: Bool {
        panel?.isVisible == true
    }

    public func updateItems(_ items: [NSDictionary]) {
        let updatedItems = items.enumerated().map { offset, element in
            StatusClipItem(dictionary: element, index: offset)
        }
        if viewModel.items != updatedItems {
            viewModel.items = updatedItems
        }
    }

    public func resetSearch() {
        viewModel.searchText = ""
    }

    public func setFavoritesStoreActive(_ active: Bool) {
		guard viewModel.isFavoritesStoreActive != active else { return }
        viewModel.isFavoritesStoreActive = active
		viewModel.scrollResetToken += 1
    }

    public var currentSearchText: String {
        viewModel.searchText
    }

    @objc(toggleWithRelativeTo:of:)
    public func toggle(relativeTo positioningRect: NSRect, of positioningView: NSView) {
        if isShown {
            closePopover()
            return
        }

        viewModel.searchText = ""
        viewModel.scrollResetToken += 1

        let height = popoverHeight(relativeTo: positioningRect, of: positioningView)
        viewModel.preferredHeight = height
        applyContentSize(NSSize(width: FloatcutStatusPopoverLayout.width, height: height))

        showPanel(relativeTo: positioningRect, of: positioningView, height: height)
    }

    public func closePopover() {
        dismissPanel(notifyDelegate: false)
    }

    private func applyContentSize(_ size: NSSize) {
        let panelSize = NSSize(
            width: size.width,
            height: size.height + FloatcutStatusPopoverLayout.arrowHeight
        )
        hostingController.preferredContentSize = panelSize
        hostingController.view.setFrameSize(panelSize)
        hostingController.view.needsLayout = true
        hostingController.view.layoutSubtreeIfNeeded()
    }

    private func showPanel(relativeTo positioningRect: NSRect, of positioningView: NSView, height: CGFloat) {
        guard let window = positioningView.window,
              let screen = window.screen ?? NSScreen.main else {
            return
        }

        positioningWindow = window

        let frame = panelFrame(relativeTo: positioningRect, of: positioningView, height: height, screen: screen)
        let panel = FloatcutStatusPanel(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hostingController
        hostingController.view.frame = NSRect(origin: .zero, size: frame.size)

        self.panel = panel
        startMonitoringEvents()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func panelFrame(relativeTo positioningRect: NSRect, of positioningView: NSView, height: CGFloat, screen: NSScreen) -> NSRect {
        guard let window = positioningView.window else {
            return NSRect(
                x: screen.visibleFrame.maxX - FloatcutStatusPopoverLayout.width - FloatcutStatusPopoverLayout.screenMargin,
                y: screen.visibleFrame.minY + FloatcutStatusPopoverLayout.screenMargin,
                width: FloatcutStatusPopoverLayout.width,
                height: height + FloatcutStatusPopoverLayout.arrowHeight
            )
        }

        let rectInWindow = positioningView.convert(positioningRect, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        let visibleFrame = screen.visibleFrame
        let panelHeight = height + FloatcutStatusPopoverLayout.arrowHeight
        let minX = visibleFrame.minX + FloatcutStatusPopoverLayout.screenMargin
        let maxX = visibleFrame.maxX - FloatcutStatusPopoverLayout.width - FloatcutStatusPopoverLayout.screenMargin
        let centeredX = rectInScreen.midX - (FloatcutStatusPopoverLayout.width / 2.0)
        let originX = maxX >= minX
            ? min(max(centeredX, minX), maxX)
            : visibleFrame.midX - (FloatcutStatusPopoverLayout.width / 2.0)
        let originY = max(
            visibleFrame.minY + FloatcutStatusPopoverLayout.screenMargin,
            rectInScreen.minY - panelHeight
        )

        viewModel.arrowX = min(
            max(FloatcutStatusPopoverLayout.arrowWidth / 2.0, rectInScreen.midX - originX),
            FloatcutStatusPopoverLayout.width - (FloatcutStatusPopoverLayout.arrowWidth / 2.0)
        )

        return NSRect(
            x: originX,
            y: originY,
            width: FloatcutStatusPopoverLayout.width,
            height: panelHeight
        )
    }

    private func dismissPanel(notifyDelegate: Bool) {
        stopMonitoringEvents()
        panel?.orderOut(nil)
        panel = nil
        positioningWindow = nil
        applyContentSize(NSSize(width: FloatcutStatusPopoverLayout.width, height: viewModel.preferredHeight))

        if notifyDelegate {
            bridgeDelegate?.statusPopoverControllerDidClose(self)
        }
    }

    private func startMonitoringEvents() {
        stopMonitoringEvents()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissPanel(notifyDelegate: true)
                return nil
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window === self.panel || event.window === self.positioningWindow {
                    return event
                }

                self.dismissPanel(notifyDelegate: true)
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel(notifyDelegate: true)
        }
    }

    private func stopMonitoringEvents() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func popoverHeight(relativeTo positioningRect: NSRect, of positioningView: NSView) -> CGFloat {
        guard let window = positioningView.window,
              let screen = window.screen ?? NSScreen.main else {
            return FloatcutStatusPopoverLayout.preferredHeight
        }

        let rectInWindow = positioningView.convert(positioningRect, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        let availableBelow = rectInScreen.minY
            - screen.visibleFrame.minY
            - FloatcutStatusPopoverLayout.screenMargin
            - FloatcutStatusPopoverLayout.arrowHeight

        return max(240, floor(availableBelow))
    }
}
