import AppKit
import ImageIO

/// UI-facing cache and request registry are main-thread owned. ImageIO work is
/// limited to two simultaneous decodes; identical in-flight requests share work.
@objc public final class FloatcutThumbnailService: NSObject {
    @objc public static let shared = FloatcutThumbnailService()
    private let cache = NSCache<NSString, NSImage>()
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "de.meierkarsten.floatcut.thumbnails"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pending: [NSString: [(NSImage?) -> Void]] = [:]

    override init() {
        super.init()
        cache.countLimit = 160
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private func key(_ identifier: String, size: CGFloat, scale: CGFloat) -> NSString {
        "\(identifier)|square|\(size)|\(max(1, Int(ceil(size * scale))))" as NSString
    }

    @objc public func cachedImage(identifier: String, size: CGFloat, scale: CGFloat) -> NSImage? {
        precondition(Thread.isMainThread)
        return cache.object(forKey: key(identifier, size: size, scale: scale))
    }

    @objc public func request(data: Data, identifier: String, size: CGFloat, scale: CGFloat,
                              completion: @escaping (NSImage?) -> Void) {
        precondition(Thread.isMainThread)
        let cacheKey = key(identifier, size: size, scale: scale)
        if let cached = cache.object(forKey: cacheKey) { completion(cached); return }
        if pending[cacheKey] != nil { pending[cacheKey]?.append(completion); return }
        pending[cacheKey] = [completion]
        let pixels = max(1, Int(ceil(size * scale)))
        workers.addOperation { [weak self] in
            let cgImage: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                ] as CFDictionary)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
                if let image, let cgImage {
                    self.cache.setObject(image, forKey: cacheKey, cost: cgImage.bytesPerRow * cgImage.height)
                }
                let callbacks = self.pending.removeValue(forKey: cacheKey) ?? []
                for callback in callbacks { callback(image) }
            }
        }
    }
}
