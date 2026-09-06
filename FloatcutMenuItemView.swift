import AppKit
import SwiftUI

private final class FloatcutMenuItemViewModel: ObservableObject {
    @Published var title = ""
    @Published var metadata = ""
    @Published var isImage = false
    @Published var previewImage: NSImage?
    @Published var hovered = false
    @Published var pressed = false
}

private struct FloatcutMenuItemRootView: View {
    @ObservedObject var model: FloatcutMenuItemViewModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isImage, let previewImage = model.previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .italic(model.isImage)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !model.metadata.isEmpty {
                    Text(model.metadata)
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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 368, height: 48, alignment: .leading)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .clipped()
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(model.hovered || model.pressed ? 0.14 : 0.06), lineWidth: 1)
            )
    }

    private var backgroundColor: Color {
        if model.pressed {
            return Color.primary.opacity(0.16)
        }

        if model.hovered {
            return Color.primary.opacity(0.10)
        }

        return Color.primary.opacity(0.03)
    }
}

private final class FloatcutMenuItemHostingView: NSHostingView<FloatcutMenuItemRootView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@objcMembers public final class FloatcutMenuItemView: NSView {
    private static let preferredSize = NSSize(width: 368, height: 48)

    private let model = FloatcutMenuItemViewModel()
    private let hostingView: FloatcutMenuItemHostingView
    private var trackingAreaRef: NSTrackingArea?

    public override var isFlipped: Bool {
        true
    }

    public override var intrinsicContentSize: NSSize {
        Self.preferredSize
    }

    public init(item: NSDictionary) {
        self.hostingView = FloatcutMenuItemHostingView(rootView: FloatcutMenuItemRootView(model: model))
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)

        setAccessibilityRole(.button)
        update(with: item)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingAreaRef = newTrackingArea
    }

    public override func mouseEntered(with event: NSEvent) {
        model.hovered = true
    }

    public override func mouseExited(with event: NSEvent) {
        model.hovered = false
        model.pressed = false
    }

    public override func mouseDown(with event: NSEvent) {
        model.pressed = true
    }

    public override func mouseUp(with event: NSEvent) {
        let clickPoint = convert(event.locationInWindow, from: nil)
        let shouldActivate = bounds.contains(clickPoint)
        model.pressed = false

        if shouldActivate {
            activateMenuItem()
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    private func update(with item: NSDictionary) {
        model.title = item["title"] as? String ?? ""
        model.isImage = (item["isImage"] as? NSNumber)?.boolValue ?? false

        let sourceName = item["sourceName"] as? String ?? ""
        let dateText = item["dateText"] as? String ?? ""
        model.metadata = [sourceName, dateText]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")

        if let previewData = item["previewData"] as? Data {
            model.previewImage = NSImage(data: previewData)
        } else {
            model.previewImage = nil
        }

        setAccessibilityLabel(model.metadata.isEmpty ? model.title : "\(model.title), \(model.metadata)")
    }

    private func activateMenuItem() {
        guard let menuItem = enclosingMenuItem, let menu = menuItem.menu else {
            return
        }

        let itemIndex = menu.index(of: menuItem)
        guard itemIndex >= 0 else {
            return
        }

        menu.cancelTrackingWithoutAnimation()
        menu.performActionForItem(at: itemIndex)
    }
}
