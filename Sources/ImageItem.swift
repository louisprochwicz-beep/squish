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

    var displayName: String { sourceURL.lastPathComponent }

    var savings: Double? {
        guard let p = processedBytes else { return nil }
        return Theme.percentSavings(original: originalBytes, processed: p)
    }
}
