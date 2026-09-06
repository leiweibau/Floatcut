import AppKit
import SwiftUI

private final class FloatcutBezelViewModel: ObservableObject {
    @Published var text = ""
    @Published var status = NSLocalizedString("Empty", comment: "")
    @Published var source = ""
    @Published var date = ""
    @Published var sourceIcon: NSImage?
    @Published var previewImage: NSImage?
    @Published var accentMode = false
    @Published var showSource = true
}

private struct FloatcutBezelRootView: View {
    @ObservedObject var model: FloatcutBezelViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(borderGradient, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 0) {
                topMetadataRow

                Spacer(minLength: 18)

                HStack(alignment: .center, spacing: 18) {
                    Text(model.text)
                        .font(.system(size: 26, weight: .semibold))
                        .italic(model.previewImage != nil)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let previewImage = model.previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                Spacer(minLength: 18)

                HStack {
                    Spacer(minLength: 0)
                    Text(model.status)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.accentMode ? Color.orange.opacity(0.95) : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    Spacer(minLength: 0)
                }
                .frame(height: 30)
            }
            .padding(22)
        }
        .padding(6)
        .background(Color.clear)
    }

    private var topMetadataRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                if model.showSource, let sourceIcon = model.sourceIcon {
                    Image(nsImage: sourceIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Text(model.showSource ? model.source : "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(model.showSource ? model.date : "")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(alignment: .trailing)
        }
        .frame(height: model.showSource ? 24 : 0, alignment: .top)
        .opacity(model.showSource ? 1 : 0)
        .clipped()
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: model.accentMode
                ? [Color.orange.opacity(0.35), Color.white.opacity(0.10)]
                : [Color.white.opacity(0.24), Color.white.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

@objcMembers public final class FloatcutBezelContentView: NSView {
    private let model = FloatcutBezelViewModel()
    private let hostingView: NSHostingView<FloatcutBezelRootView>

    public init(frame frameRect: NSRect, showSource: Bool) {
        self.hostingView = NSHostingView(rootView: FloatcutBezelRootView(model: model))
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        model.showSource = showSource

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.setAccessibilityRole(.group)
        addSubview(hostingView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setDisplayText(_ text: String) {
        model.text = text
    }

    public func setStatusText(_ status: String) {
        model.status = status
    }

    public func setSourceText(_ source: String) {
        model.source = source
    }

    public func setDateText(_ date: String) {
        model.date = date
    }

    public func setSourceIconImage(_ image: NSImage?) {
        model.sourceIcon = image
    }

    public func setPreviewImage(_ image: NSImage?) {
        model.previewImage = image
    }

    public func setAccentMode(_ accentMode: Bool) {
        model.accentMode = accentMode
    }

    public func setShowSource(_ showSource: Bool) {
        model.showSource = showSource
    }
}
