import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum OutputFormat: String, CaseIterable, Identifiable {
    case keepOriginal = "Original"
    case jpeg = "JPEG"
    case png = "PNG"
    case webp = "WEBP"
    case heic = "HEIC"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .keepOriginal: return ""
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .webp: return "webp"
        case .heic: return "heic"
        }
    }

    var utType: UTType? {
        switch self {
        case .keepOriginal: return nil
        case .jpeg: return .jpeg
        case .png:  return .png
        case .webp: return UTType("org.webmproject.webp") ?? UTType("public.webp")
        case .heic: return UTType("public.heic")
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .png: return false
        default:   return true
        }
    }

    var symbol: String {
        switch self {
        case .keepOriginal: return "photo"
        case .jpeg: return "photo"
        case .png:  return "photo.fill"
        case .webp: return "photo.fill"
        case .heic: return "photo.fill.on.rectangle.fill"
        }
    }
}

/// Lightweight transient banner shown after a successful action (Squish, Save…).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let message: String
    let actionLabel: String?
    let actionURL: URL?  // when set, the action reveals this URL in Finder
    let duration: TimeInterval

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    static func success(_ message: String, icon: String = "checkmark.seal.fill", duration: TimeInterval = 4) -> Toast {
        Toast(icon: icon, message: message, actionLabel: nil, actionURL: nil, duration: duration)
    }

    static func exported(at url: URL, count: Int) -> Toast {
        let plural = count > 1 ? "s" : ""
        return Toast(
            icon: "checkmark.seal.fill",
            message: "Exported \(count) image\(plural)",
            actionLabel: "Show in Finder",
            actionURL: url,
            duration: 6
        )
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var items: [ImageItem] = []
    @Published var outputFormat: OutputFormat = .webp
    @Published var quality: Double = 0.70
    @Published var targetWidth: Int? = nil
    @Published var targetHeight: Int? = nil
    @Published var stripMetadata: Bool = true
    @Published var isDarkMode: Bool = true
    @Published var isProcessing: Bool = false
    @Published var dragOver: Bool = false
    @Published var lastExportFolder: URL? = nil
    @Published var toast: Toast? = nil
    private var toastDismissTask: Task<Void, Never>?
    /// Held so the batch Squish operation can be cancelled (e.g. when the
    /// user clears all items mid-processing).
    var processingTask: Task<Void, Never>?

    // Resize behaviour is now implicit:
    //   • one dim filled  → proportional resize (image aspect ratio preserved)
    //   • both dims filled → scale-to-fill + center crop to exact W × H

    var totalOriginalBytes: Int {
        items.reduce(0) { $0 + $1.originalBytes }
    }

    var totalProcessedBytes: Int {
        items.reduce(0) { $0 + ($1.processedBytes ?? 0) }
    }

    var anyProcessed: Bool {
        items.contains { $0.processedBytes != nil }
    }

    /// Accepts any mix of file and folder URLs. Folders are expanded
    /// recursively, keeping only files with a supported image extension.
    func addItems(from urls: [URL]) {
        let resolved = Self.resolveImageURLs(urls)
        for url in resolved {
            if items.contains(where: { $0.sourceURL == url }) { continue }
            if let item = ImageItem(url: url) {
                items.append(item)
                Task { await loadThumbnail(for: item) }
            }
        }
        scheduleEstimates()
    }

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"
    ]

    private static func resolveImageURLs(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Recurse into the folder, picking up any supported image
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let sub as URL in enumerator {
                        if supportedExtensions.contains(sub.pathExtension.lowercased()) {
                            out.append(sub)
                        }
                    }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    func removeItem(_ item: ImageItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        // If a batch Squish is currently running, abort it cleanly.
        processingTask?.cancel()
        processingTask = nil
        estimateTask?.cancel()
        estimateTask = nil
        items.removeAll()
    }

    /// Show a toast banner. Replaces any current toast and schedules an auto-dismiss.
    func showToast(_ toast: Toast) {
        toastDismissTask?.cancel()
        self.toast = toast
        let toastID = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            if self?.toast?.id == toastID {
                self?.toast = nil
            }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
    }

    private func loadThumbnail(for item: ImageItem) async {
        let url = item.sourceURL
        let thumb: NSImage? = await Task.detached(priority: .userInitiated) {
            ImageProcessor.makeThumbnail(url: url, maxPixel: 512)
        }.value
        item.thumbnail = thumb
        item.sourceThumbnail = thumb  // keep an unedited copy for the editor
    }

    /// Rebuilds the card preview to reflect the per-item edits (crop, rotation,
    /// flip). Called after the editor sheet's Apply so the card matches reality.
    func reloadEditedThumbnail(for item: ImageItem) {
        let url = item.sourceURL
        let opts = ProcessOptions(
            format: outputFormat,
            quality: quality,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            stripMetadata: stripMetadata,
            rotationDegrees: item.rotationDegrees,
            flipHorizontal: item.flipHorizontal,
            cropRectNormalized: item.cropRectNormalized
        )
        Task {
            let thumb = await Task.detached(priority: .userInitiated) {
                ImageProcessor.makeEditedThumbnail(url: url, options: opts)
            }.value
            if let thumb {
                item.thumbnail = thumb
            }
        }
    }

    // MARK: - Live size estimate (debounced)

    private var estimateTask: Task<Void, Never>?

    /// Call whenever a setting changes that affects output size
    /// (format, quality, target W/H, strip metadata, or a new item is added).
    func scheduleEstimates() {
        estimateTask?.cancel()
        estimateTask = Task { [weak self] in
            // Debounce — wait for the user to stop fiddling with the slider
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await self?.runEstimates()
        }
    }

    private func runEstimates() async {
        let snapshot = items   // SwiftUI guarantees @Published reads on main
        let opts = baseOptions()

        for item in snapshot {
            if Task.isCancelled { return }
            item.estimating = true
            let url = item.sourceURL
            let itemOpts = ProcessOptions(
                format: opts.format,
                quality: opts.quality,
                targetWidth: opts.targetWidth,
                targetHeight: opts.targetHeight,
                stripMetadata: opts.stripMetadata,
                rotationDegrees: item.rotationDegrees,
                flipHorizontal: item.flipHorizontal,
                cropRectNormalized: item.cropRectNormalized
            )
            let bytes = await Task.detached(priority: .userInitiated) {
                ImageProcessor.estimateSize(url: url, options: itemOpts)
            }.value
            if Task.isCancelled { return }
            item.estimatedBytes = bytes
            item.estimating = false
        }
    }

    private func baseOptions() -> ProcessOptions {
        ProcessOptions(
            format: outputFormat,
            quality: quality,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            stripMetadata: stripMetadata,
            rotationDegrees: 0,
            flipHorizontal: false,
            cropRectNormalized: nil
        )
    }
}
