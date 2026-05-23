import Foundation
import PDFKit
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Converts a PDF document into one PNG-on-disk per page so the rest of
/// Squish's pipeline can treat each page as just-another-image.
///
/// PDFKit is bundled with macOS (since 10.4) — no extra dependency, no
/// API key, no network. We render each page through a custom CGContext
/// (vs `PDFPage.thumbnail()`) so we can:
///   • paint a white background first — PDFs often have transparent
///     pages; without this they'd export as black blobs in JPEG.
///   • choose any DPI; default 150 DPI gives ~1.2 MP for A4, a good
///     compromise between visual quality and file size.
///
/// All output files land in `FileManager.default.temporaryDirectory`
/// with a `squish-pdf-` prefix so AppState can clean them up later.
enum PDFRenderer {

    /// Default rendering DPI. 150 DPI ≈ 1240×1750 for A4 — sharper than
    /// screen (72 DPI) but a lot lighter than print (300 DPI).
    static let defaultDPI: CGFloat = 150

    /// PDF coordinate space is 1/72 inch per point.
    private static let pdfPointsPerInch: CGFloat = 72

    /// Render every page of the PDF at `url` to a temp PNG file. Returns
    /// the page URLs in document order. Failed pages (rare) are skipped
    /// rather than aborting the whole import.
    static func renderPages(of url: URL, dpi: CGFloat = defaultDPI) -> [URL] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return []
        }

        // Stable per-document ID so two simultaneous imports of the same
        // PDF (or two PDFs with the same name) don't collide on disk.
        let docID = String(UUID().uuidString.prefix(8))
        let stem = sanitizeStem(url.deletingPathExtension().lastPathComponent)
        let tempDir = FileManager.default.temporaryDirectory
        let scale = dpi / pdfPointsPerInch

        var rendered: [URL] = []
        rendered.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            // Wrap each page in an autoreleasepool — a 50-page PDF
            // otherwise piles up its rendered CGImage buffers until
            // the call returns, peaking memory unnecessarily.
            autoreleasepool {
                guard let page = document.page(at: pageIndex),
                      let cgImage = renderPage(page, scale: scale)
                else { return }

                let pageNumber = pageIndex + 1
                let pageURL = tempDir.appendingPathComponent(
                    "squish-pdf-\(docID)-\(stem)-page-\(pageNumber).png"
                )

                if writePNG(cgImage, to: pageURL) {
                    rendered.append(pageURL)
                }
            }
        }

        return rendered
    }

    // MARK: - Per-page render

    private static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        // Use the .mediaBox — the full page including any bleed; matches
        // what users see when they open the PDF in Preview / Adobe.
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        let pixelW = max(1, Int(ceil(mediaBox.width * scale)))
        let pixelH = max(1, Int(ceil(mediaBox.height * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = 4 * pixelW
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 1. White background — PDFs are vector + often transparent;
        //    rendering on a black context would produce black pages
        //    when exported to a format without alpha (JPEG, etc.).
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // 2. Scale the context so page-coordinate drawing maps 1:1
        //    onto our target pixel grid.
        ctx.scaleBy(x: scale, y: scale)

        // 3. Origin shift if the mediaBox doesn't start at (0,0).
        ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)

        // 4. Hand off to PDFKit.
        page.draw(with: .mediaBox, to: ctx)

        return ctx.makeImage()
    }

    private static func writePNG(_ cgImage: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Naming helpers

    /// Make the PDF filename safe for our temp paths. We don't go fully
    /// ASCII (the user may rename later), just kill `/` and `:` which
    /// would break path construction and pull leading dots.
    private static func sanitizeStem(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// Returns true if `url` points at a file Squish created itself
    /// during a PDF import — used by AppState to clean up temp pages
    /// when an item is removed or the batch is cleared.
    static func isRenderedPageURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.path
            && url.lastPathComponent.hasPrefix("squish-pdf-")
    }
}
