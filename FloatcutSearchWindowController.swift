import AppKit
import ImageIO
import SwiftUI

@objc public protocol FloatcutSearchWindowControllerDelegate: AnyObject {
    func searchWindowController(_ controller: FloatcutSearchWindowController, didSelectStoreIndex storeIndex: NSNumber)
    func searchWindowController(_ controller: FloatcutSearchWindowController, searchTextDidChange searchText: String)
    func searchWindowControllerDidClose(_ controller: FloatcutSearchWindowController)
}

private struct SearchClipItem: Identifiable, Equatable {
    let id: String
    let storeIndex: Int
    let title: String
    let isImage: Bool
    let isRemoteSync: Bool
    let previewData: Data?

    init(dictionary: NSDictionary, index: Int) {
        self.storeIndex = (dictionary["storeIndex"] as? NSNumber)?.intValue ?? index
        self.id = dictionary["clippingID"] as? String ?? "legacy-\(self.storeIndex)"
        self.title = dictionary["title"] as? String ?? ""
        self.isImage = (dictionary["isImage"] as? NSNumber)?.boolValue ?? false
        self.isRemoteSync = (dictionary["isRemoteSync"] as? NSNumber)?.boolValue ?? false
        if let data = dictionary["previewData"] as? Data {
            self.previewData = data
        } else {
            self.previewData = nil
        }
    }

    static func == (lhs: SearchClipItem, rhs: SearchClipItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.storeIndex == rhs.storeIndex &&
        lhs.title == rhs.title &&
        lhs.isImage == rhs.isImage &&
        lhs.isRemoteSync == rhs.isRemoteSync
    }
}

private final class SearchClipViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [SearchClipItem] = []
}

private final class SearchThumbnailLoader: ObservableObject {
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

private struct SearchThumbnailView: View {
    let previewData: Data?
    let cacheKey: NSString
    let size: CGFloat

    @StateObject private var loader = SearchThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onAppear {
            loader.load(previewData: previewData, cacheKey: cacheKey, size: size)
        }
        .onChange(of: cacheKey as String) { _ in
            loader.load(previewData: previewData, cacheKey: cacheKey, size: size)
        }
    }
}

private struct SearchClipRowView: View {
    let item: SearchClipItem
    @AppStorage("remoteClipBorderRed") private var remoteClipBorderRed = FloatcutRemoteClipBorderAppearance.defaultRed
    @AppStorage("remoteClipBorderGreen") private var remoteClipBorderGreen = FloatcutRemoteClipBorderAppearance.defaultGreen
    @AppStorage("remoteClipBorderBlue") private var remoteClipBorderBlue = FloatcutRemoteClipBorderAppearance.defaultBlue
    @AppStorage("remoteClipBorderTransparency") private var remoteClipBorderTransparency = FloatcutRemoteClipBorderAppearance.defaultTransparency

    var body: some View {
        HStack(spacing: 10) {
            if item.isImage {
                SearchThumbnailView(
                    previewData: item.previewData,
                    cacheKey: "\(item.id)-18" as NSString,
                    size: 18
                )
            }

            if item.isImage {
                Text(LocalizedStringKey("Image"))
                    .italic()
                    .lineLimit(1)
            } else {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
}

private struct SearchWindowContentView: View {
    @ObservedObject var viewModel: SearchClipViewModel
    let activate: (Int) -> Void
    let searchChanged: (String) -> Void

    @State private var selection: Int?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            TextField(LocalizedStringKey("Search"), text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    activateSelection()
                }

            List(viewModel.items, selection: $selection) { item in
                SearchClipRowView(item: item)
                    .tag(item.storeIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = item.storeIndex
                    }
                    .onTapGesture(count: 2) {
                        activate(item.storeIndex)
                    }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .background(.regularMaterial)
        .onAppear {
            selection = selection ?? viewModel.items.first?.storeIndex
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: viewModel.items) { _ in
            syncSelection()
        }
        .onChange(of: viewModel.searchText) { _ in
            syncSelection()
            searchChanged(viewModel.searchText)
        }
    }

    private func syncSelection() {
        let newValue = viewModel.items
        if let selection, !newValue.contains(where: { $0.storeIndex == selection }) {
            self.selection = newValue.first?.storeIndex
        } else if self.selection == nil {
            self.selection = newValue.first?.storeIndex
        }
    }

    private func activateSelection() {
        if let selection {
            activate(selection)
        } else if let first = viewModel.items.first {
            activate(first.storeIndex)
        }
    }
}

private final class FloatcutSearchHostWindow: NSWindow {
    var closeHandler: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        closeHandler?()
    }

    override func performClose(_ sender: Any?) {
        closeHandler?()
    }
}

@objcMembers public final class FloatcutSearchWindowController: NSWindowController, NSWindowDelegate {
    public weak var bridgeDelegate: FloatcutSearchWindowControllerDelegate?

    private let viewModel = SearchClipViewModel()
    private var isVisible = false

    public init() {
        let window = FloatcutSearchHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: SearchWindowContentView(viewModel: viewModel, activate: { _ in }, searchChanged: { _ in }))

        window.contentView = hostingView
        window.title = NSLocalizedString("Search Clipboard", comment: "")
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        hostingView.rootView = SearchWindowContentView(
            viewModel: viewModel,
            activate: { [weak self] index in
                if let self {
                    self.bridgeDelegate?.searchWindowController(self, didSelectStoreIndex: NSNumber(value: index))
                    self.hideWindow()
                }
            },
            searchChanged: { [weak self] searchText in
                guard let self else { return }
                self.bridgeDelegate?.searchWindowController(self, searchTextDidChange: searchText)
            }
        )

        window.delegate = self
        window.closeHandler = { [weak self] in
            self?.hideWindow()
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func updateItems(_ items: [NSDictionary]) {
        let updatedItems = items.enumerated().map { offset, element in
            SearchClipItem(dictionary: element, index: offset)
        }
        if viewModel.items != updatedItems {
            viewModel.items = updatedItems
        }
    }

    public func resetSearch() {
        viewModel.searchText = ""
    }

    public func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    public func hideWindow() {
        guard isVisible else { return }
        window?.orderOut(nil)
        isVisible = false
        bridgeDelegate?.searchWindowControllerDidClose(self)
    }

    public func windowWillClose(_ notification: Notification) {
        if isVisible {
            isVisible = false
            bridgeDelegate?.searchWindowControllerDidClose(self)
        }
    }
}
