import Foundation
import AppKit
import UniformTypeIdentifiers

enum ProcessingStatus: Equatable {
    case pending
    case processing
    case done
    case failed(String)
}

@MainActor
final class ImageItem: ObservableObject, Identifiable {
    let id = UUID()
    let sourceURL: URL
    let originalBytes: Int
    let originalPixelSize: CGSize
    let sourceUTType: UTType?

    @Published var thumbnail: NSImage?           // edited preview (for the card)
    @Published var sourceThumbnail: NSImage?     // untouched original (for the editor preview)
    @Published var processedBytes: Int?
    @Published var processedData: Data?
    @Published var processedExtension: String?
    @Published var processedPixelSize: CGSize?
    @Published var status: ProcessingStatus = .pending
    @Published var rotationDegrees: Int = 0    // 0, 90, 180, 270
    @Published var flipHorizontal: Bool = false
    @Published var cropRectNormalized: CGRect? = nil  // 0..1 coords
    @Published var estimatedBytes: Int? = nil   // live preview of compressed size
    @Published var estimating: Bool = false
    /// Snapshot of the options that were used the last time this item was
    /// successfully processed. Compared against the *current* options to
    /// detect whether the item is "stale" and needs to be re-squished — e.g.
    /// because the user changed the format, the quality slider, the target
    /// W/H, or re-cropped/rotated the image since the previous Squish.
    @Published var lastProcessedOptions: ProcessOptions? = nil
    /// Optional user-supplied basename (without extension) set via the
    /// inline rename field in the editor. nil → use the source file's
    /// basename. The source file on disk is NEVER renamed; this only
    /// affects what the editor & card show, and the exported file's name.
    @Published var customBaseName: String? = nil
    /// True while an AI rename request is in flight for this item, so
    /// the card can render a subtle spinner over the filename overlay.
    @Published var aiRenaming: Bool = false
    /// Drives the entrance animation. Starts false on init so the card
    /// renders invisible/scaled-down on first paint; AppState flips it
    /// to true with a small per-item stagger so a batch of dropped
    /// images cascades in instead of appearing all at once.
    @Published var hasAppeared: Bool = false
    /// When true, the export pipeline strips the background using
    /// Apple Vision's foreground segmentation model and exports the
    /// result with an alpha channel (force-switching to PNG/WEBP if
    /// the user picked JPEG). Toggled from the editor sheet. The
    /// actual mask is cached in BackgroundRemover keyed by `id`.
    @Published var removeBackground: Bool = false

    init?(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return nil
        }
        self.sourceURL = url
        self.originalBytes = size

        // Probe pixel dimensions + UTType
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = (props?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
            let h = (props?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
            self.originalPixelSize = CGSize(width: w, height: h)
            if let typeID = CGImageSourceGetType(src) {
                self.sourceUTType = UTType(typeID as String)
            } else {
                self.sourceUTType = nil
            }
        } else {
            self.originalPixelSize = .zero
            self.sourceUTType = nil
        }
    }

    /// The basename (without extension) the user sees & can edit. Falls
    /// back to the source file's basename when no custom name is set.
    var editableBaseName: String {
        customBaseName ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    /// File extension from the source (kept stable in the editor header
    /// so the user knows what they're editing). The actual exported file
    /// extension is determined by the chosen output format and may differ.
    var sourceExtension: String { sourceURL.pathExtension }

    /// Full filename as shown in the card overlay and elsewhere
    /// (basename + extension). Honours customBaseName when set.
    var displayName: String {
        let base = editableBaseName
        let ext = sourceExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    var savings: Double? {
        guard let p = processedBytes else { return nil }
        return Theme.percentSavings(original: originalBytes, processed: p)
    }
}
