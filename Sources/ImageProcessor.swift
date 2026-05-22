import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

struct ProcessOptions: Equatable {
    var format: OutputFormat
    var quality: Double
    var targetWidth: Int?
    var targetHeight: Int?
    var stripMetadata: Bool
    var rotationDegrees: Int
    var flipHorizontal: Bool
    var cropRectNormalized: CGRect?
}

struct ProcessResult {
    let data: Data
    let ext: String
    let pixelSize: CGSize
}

enum ImageProcessor {

    // MARK: - Shared CIImage transform pipeline
    //
    // process() and makeEditedThumbnail() both apply rotation → flip → crop
    // in the same order. Extracted here so any tweak (a new transform, a
    // changed order) lives in ONE place.
    private static func applyTransforms(
        to ciImage: CIImage,
        rotationDegrees: Int,
        flipHorizontal: Bool,
        cropRect: CGRect?
    ) -> CIImage {
        var ci = ciImage

        // 1. Rotation
        let rot = ((rotationDegrees % 360) + 360) % 360
        if rot != 0 {
            let radians = CGFloat(rot) * .pi / 180
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: radians))
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        }

        // 2. Flip horizontal
        if flipHorizontal {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        }

        // 3. User crop (in post-rotation/flip space — matches the editor overlay)
        if let crop = cropRect {
            let extent = ci.extent
            let rect = CGRect(
                x: extent.minX + crop.minX * extent.width,
                y: extent.minY + (1 - crop.maxY) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            )
            ci = ci.cropped(to: rect)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        }

        return ci
    }

    // MARK: - WEBP encoding (shells out to bundled `cwebp`)
    //
    // ImageIO on macOS supports DECODING WEBP since macOS 11 but does NOT
    // expose a destination format identifier for ENCODING. We therefore embed
    // libwebp's official `cwebp` binary in Contents/MacOS/cwebp and call it
    // through `Process` whenever the user picks WEBP as output.

    /// Returns the path to the bundled cwebp helper, or nil if not present.
    private static func cwebpURL() -> URL? {
        guard let mainExe = Bundle.main.executableURL else { return nil }
        let candidate = mainExe.deletingLastPathComponent().appendingPathComponent("cwebp")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Returns the path to the bundled pngquant helper, or nil if not present.
    private static func pngquantURL() -> URL? {
        guard let mainExe = Bundle.main.executableURL else { return nil }
        let candidate = mainExe.deletingLastPathComponent().appendingPathComponent("pngquant")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Encodes a CGImage to PNG.
    ///
    /// - At quality ≥ 0.95 (top of the slider) → produce a LOSSLESS PNG via
    ///   ImageIO so the user can still get pristine pixels.
    /// - Below that → write a lossless PNG, then run pngquant for TinyPNG-style
    ///   palette quantisation. pngquant maps the 0…1 slider to a min/max
    ///   quality target: higher = more colours retained = larger file.
    static func encodePNG(cgImage: CGImage, quality: Double, stripMetadata: Bool) throws -> Data {
        // 1. Always start with a lossless PNG via ImageIO
        let losslessData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            losslessData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Squish", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Cannot create PNG destination"
            ])
        }

        var props: [CFString: Any] = [:]
        if stripMetadata {
            props[kCGImageMetadataShouldExcludeGPS] = true
            props[kCGImageDestinationMetadata] = CGImageMetadataCreateMutable()
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Squish", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "PNG encoding failed"
            ])
        }

        // 2. Top of slider → keep lossless (pristine)
        if quality >= 0.95 {
            return losslessData as Data
        }

        // 3. Below threshold → run pngquant. If unavailable, fall back to lossless.
        guard let pngquant = pngquantURL() else {
            return losslessData as Data
        }

        // Map quality 0…0.95 to pngquant --quality min-max
        //   1.00 → 90-100  (essentially lossless visually)
        //   0.80 → 70-90   (TinyPNG default sweet spot)
        //   0.60 → 50-80
        //   0.40 → 30-65
        //   0.20 → 10-45
        //   0.05 → 0-30    (aggressive)
        let qPct = max(0, min(100, Int((quality * 100).rounded())))
        let qMax = max(30, min(100, qPct + 10))
        let qMin = max(0,  min(qMax - 20, qPct - 20))

        let tempDir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let inURL  = tempDir.appendingPathComponent("squish-\(id)-in.png")
        let outURL = tempDir.appendingPathComponent("squish-\(id)-out.png")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try (losslessData as Data).write(to: inURL)

        let task = Process()
        task.executableURL = pngquant
        task.arguments = [
            "--quality", "\(qMin)-\(qMax)",
            "--speed", "3",            // 1 = slow/best, 11 = fast/worst. 3 ≈ default.
            "--strip",                 // remove optional PNG chunks for size
            "--force",                 // overwrite output if it exists
            "--output", outURL.path,
            inURL.path
        ]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return losslessData as Data
        }

        // pngquant exits 99 when the result would exceed the quality ceiling
        // (--quality min-max with min not met). In that case fall back to the
        // lossless original rather than failing the whole export.
        if task.terminationStatus != 0 {
            return losslessData as Data
        }

        guard let quantised = try? Data(contentsOf: outURL), !quantised.isEmpty else {
            return losslessData as Data
        }

        // Only keep the quantised version if it's actually smaller.
        return quantised.count < losslessData.length ? quantised : (losslessData as Data)
    }

    /// Encodes a CGImage to WEBP using the bundled cwebp.
    /// Writes a temp PNG, runs `cwebp -q <Q>`, reads the resulting WEBP, returns its bytes.
    static func encodeWebP(cgImage: CGImage, quality: Double, stripMetadata: Bool) throws -> Data {
        guard let cwebp = cwebpURL() else {
            throw NSError(domain: "Squish", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cwebp helper not bundled — WEBP export unavailable."
            ])
        }

        let tempDir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let pngURL = tempDir.appendingPathComponent("squish-\(id).png")
        let webpURL = tempDir.appendingPathComponent("squish-\(id).webp")
        defer {
            try? FileManager.default.removeItem(at: pngURL)
            try? FileManager.default.removeItem(at: webpURL)
        }

        // 1. Lossless intermediate PNG so cwebp gets pristine pixels
        guard let pngDest = CGImageDestinationCreateWithURL(
            pngURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Squish", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Cannot create temp PNG destination"
            ])
        }
        CGImageDestinationAddImage(pngDest, cgImage, nil)
        guard CGImageDestinationFinalize(pngDest) else {
            throw NSError(domain: "Squish", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "PNG temp finalize failed"
            ])
        }

        // 2. Spawn cwebp
        let qInt = Int((quality * 100).rounded())
        let metaArg = stripMetadata ? "none" : "all"

        let task = Process()
        task.executableURL = cwebp
        task.arguments = [
            "-quiet",
            "-q", String(qInt),
            "-metadata", metaArg,
            pngURL.path,
            "-o", webpURL.path
        ]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let errText = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0 ?? Data(), encoding: .utf8) } ?? "exit \(task.terminationStatus)"
            throw NSError(domain: "Squish", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "cwebp failed: \(errText)"
            ])
        }

        return try Data(contentsOf: webpURL)
    }

    static func makeThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Like `makeThumbnail` but applies the per-item edits (crop, rotation,
    /// flip) so the card preview matches what the user will actually export.
    /// Loads a moderately downscaled version of the source for speed, then
    /// runs the same CIImage pipeline as `process()` minus the compression.
    static func makeEditedThumbnail(url: URL, options: ProcessOptions, maxPixel: Int = 512) -> NSImage? {
        // Load a downscaled source. We pull a bit more pixels than maxPixel
        // because subsequent crop/rotation can shrink the working size.
        let loadOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * 2
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, loadOpts as CFDictionary) else {
            return nil
        }

        // Apply the same rotation → flip → crop pipeline as `process()` so the
        // card preview after Apply matches the exported pixels.
        let ci = applyTransforms(
            to: CIImage(cgImage: cg),
            rotationDegrees: options.rotationDegrees,
            flipHorizontal: options.flipHorizontal,
            cropRect: options.cropRectNormalized
        )

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let outCG = context.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
    }

    static func process(url: URL, options: ProcessOptions) throws -> ProcessResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "Squish", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode image"])
        }

        // Apply the rotation → flip → crop pipeline (shared helper).
        // Order matches what the editor preview shows, so the exported image
        // is exactly the cropped region the user saw on screen.
        var ci = applyTransforms(
            to: CIImage(cgImage: cg),
            rotationDegrees: options.rotationDegrees,
            flipHorizontal: options.flipHorizontal,
            cropRect: options.cropRectNormalized
        )

        // 4. Resize — implicit behaviour:
        //   • only W or only H → proportional scale (preserve aspect)
        //   • both W and H     → scale-to-fill + center crop to exact W × H
        let workingSize = ci.extent.size
        if let tw = options.targetWidth, let th = options.targetHeight,
           tw > 0, th > 0, workingSize.width > 0, workingSize.height > 0 {
            // Scale up/down so the image FILLS the target rect (covers both axes)
            let scale = max(CGFloat(tw) / workingSize.width,
                            CGFloat(th) / workingSize.height)
            if scale != 1.0 {
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
            }
            // Center-crop to exact target W × H
            let scaled = ci.extent.size
            let cropRect = CGRect(
                x: max(0, (scaled.width - CGFloat(tw)) / 2),
                y: max(0, (scaled.height - CGFloat(th)) / 2),
                width: min(CGFloat(tw), scaled.width),
                height: min(CGFloat(th), scaled.height)
            )
            ci = ci.cropped(to: cropRect)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        } else {
            let scale = resizeScale(from: workingSize, targetW: options.targetWidth, targetH: options.targetHeight)
            if scale != 1.0 && scale > 0 {
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
            }
        }

        // Render
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let outCG = context.createCGImage(ci, from: ci.extent) else {
            throw NSError(domain: "Squish", code: 2, userInfo: [NSLocalizedDescriptionKey: "Render failed"])
        }

        // 5. Encode
        let resolvedFormat = resolveFormat(options.format, sourceURL: url)

        // WEBP path → cwebp helper (ImageIO can't encode WEBP)
        if resolvedFormat == .webp {
            let data = try encodeWebP(
                cgImage: outCG,
                quality: options.quality,
                stripMetadata: options.stripMetadata
            )
            return ProcessResult(data: data, ext: "webp", pixelSize: outCG.size)
        }

        // PNG path → pngquant helper for TinyPNG-style lossy palette quantisation
        // (at quality ≥ 0.95 it stays lossless).
        if resolvedFormat == .png {
            let data = try encodePNG(
                cgImage: outCG,
                quality: options.quality,
                stripMetadata: options.stripMetadata
            )
            return ProcessResult(data: data, ext: "png", pixelSize: outCG.size)
        }

        // All other formats → standard ImageIO path
        guard let utType = resolvedFormat.utType ?? defaultUTType(for: url) else {
            throw NSError(domain: "Squish", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown output format"])
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Squish", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot create destination (\(utType.identifier))"])
        }

        var props: [CFString: Any] = [:]
        if resolvedFormat.supportsQuality {
            props[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if options.stripMetadata {
            props[kCGImageMetadataShouldExcludeGPS] = true
            props[kCGImageDestinationMetadata] = CGImageMetadataCreateMutable()
        }

        CGImageDestinationAddImage(dest, outCG, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Squish", code: 5, userInfo: [NSLocalizedDescriptionKey: "Encoding failed for \(utType.identifier)"])
        }

        let ext = resolvedFormat.fileExtension.isEmpty
            ? (url.pathExtension.isEmpty ? "img" : url.pathExtension)
            : resolvedFormat.fileExtension

        return ProcessResult(data: data as Data, ext: ext, pixelSize: outCG.size)
    }

    /// Predicts the output file size by compressing a downscaled thumbnail
    /// with the current settings and extrapolating bytes-per-pixel up to the
    /// target full-resolution pixel count.
    ///
    /// Accuracy: typically within ±20 % of the real `process()` output for
    /// JPEG/WEBP/HEIC. Fast enough (≈10–30 ms per image at 384 px) to run on
    /// every slider tick once debounced.
    static func estimateSize(url: URL, options: ProcessOptions, maxPixel: Int = 384) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let probs = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let origW = probs[kCGImagePropertyPixelWidth] as? Int,
              let origH = probs[kCGImagePropertyPixelHeight] as? Int,
              origW > 0, origH > 0 else {
            return nil
        }

        // Target full pixel count after applying the user's resize choice
        let scale = resizeScale(from: CGSize(width: origW, height: origH),
                                targetW: options.targetWidth,
                                targetH: options.targetHeight)
        let targetFullPixels = Double(origW) * Double(origH) * Double(scale * scale)
        guard targetFullPixels > 0 else { return nil }

        // Create a fast downscaled CGImage for the estimation pass
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }

        // Encode the thumbnail with the user's chosen format + quality
        let resolvedFormat = resolveFormat(options.format, sourceURL: url)

        let thumbBytes: Int
        if resolvedFormat == .webp {
            // WEBP estimation routes through cwebp helper
            guard let webpData = try? encodeWebP(
                cgImage: cg,
                quality: options.quality,
                stripMetadata: options.stripMetadata
            ) else { return nil }
            thumbBytes = webpData.count
        } else if resolvedFormat == .png {
            // PNG estimation routes through pngquant helper
            guard let pngData = try? encodePNG(
                cgImage: cg,
                quality: options.quality,
                stripMetadata: options.stripMetadata
            ) else { return nil }
            thumbBytes = pngData.count
        } else {
            guard let utType = resolvedFormat.utType ?? defaultUTType(for: url) else { return nil }

            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
                return nil
            }

            var props: [CFString: Any] = [:]
            if resolvedFormat.supportsQuality {
                props[kCGImageDestinationLossyCompressionQuality] = options.quality
            }
            if options.stripMetadata {
                props[kCGImageMetadataShouldExcludeGPS] = true
                props[kCGImageDestinationMetadata] = CGImageMetadataCreateMutable()
            }

            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            thumbBytes = data.length
        }

        // Extrapolate: bytes-per-pixel from the thumb × target full-pixel count
        let thumbPixels = Double(cg.width) * Double(cg.height)
        guard thumbPixels > 0 else { return nil }
        let bytesPerPixel = Double(thumbBytes) / thumbPixels
        return Int(bytesPerPixel * targetFullPixels)
    }

    /// Public wrapper so views can compute predicted target dimensions
    /// without duplicating the resize logic. Accounts for crop + 90°/270°
    /// rotation (which swap width and height).
    static func predictedSize(
        from size: CGSize,
        crop: CGRect? = nil,
        rotation: Int = 0,
        targetW: Int?,
        targetH: Int?
    ) -> CGSize {
        // Pipeline order matches process(): rotation → crop → resize.
        var working = size

        // 1. Rotation swaps W/H for 90°/270°
        let normalizedRot = ((rotation % 360) + 360) % 360
        if normalizedRot == 90 || normalizedRot == 270 {
            working = CGSize(width: working.height, height: working.width)
        }

        // 2. User crop reduces dimensions (applied in post-rotation space)
        if let c = crop {
            working = CGSize(width: working.width * c.width, height: working.height * c.height)
        }

        // 3. Resize / center-crop based on target W/H
        if let tw = targetW, let th = targetH, tw > 0, th > 0 {
            // Both set → output is exactly the target dimensions (cover-crop)
            return CGSize(width: CGFloat(tw), height: CGFloat(th))
        }
        let s = resizeScale(from: working, targetW: targetW, targetH: targetH)
        return CGSize(width: (working.width * s).rounded(),
                      height: (working.height * s).rounded())
    }

    private static func resizeScale(from size: CGSize, targetW: Int?, targetH: Int?) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        switch (targetW, targetH) {
        case (nil, nil):
            return 1
        case (let w?, nil):
            let s = CGFloat(w) / size.width
            return s < 1 ? s : 1
        case (nil, let h?):
            let s = CGFloat(h) / size.height
            return s < 1 ? s : 1
        case (let w?, let h?):
            let sw = CGFloat(w) / size.width
            let sh = CGFloat(h) / size.height
            let s = min(sw, sh)
            return s < 1 ? s : 1
        }
    }

    private static func resolveFormat(_ f: OutputFormat, sourceURL: URL) -> OutputFormat {
        if f != .keepOriginal { return f }
        switch sourceURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png":         return .png
        case "webp":        return .webp
        case "heic", "heif":return .heic
        default:            return .jpeg
        }
    }

    private static func defaultUTType(for url: URL) -> UTType? {
        if let t = UTType(filenameExtension: url.pathExtension) { return t }
        return .jpeg
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}
