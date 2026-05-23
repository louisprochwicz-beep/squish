import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine

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

    /// PNG is lossless via ImageIO but Squish bundles pngquant for TinyPNG-style
    /// palette quantisation — so the quality slider IS meaningful for PNG too.
    var supportsQuality: Bool {
        return true
    }

    /// Whether this format preserves a per-pixel alpha channel. JPEG
    /// does not; everything else we ship does. Used by ImageProcessor
    /// to auto-switch the export format on per-item basis when the
    /// user enabled "Remove background" on an image that otherwise
    /// would have been exported as JPEG.
    var supportsAlpha: Bool {
        switch self {
        case .jpeg: return false
        case .png, .webp, .heic, .keepOriginal: return true
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
    /// True while a batch "Rename with AI" pass is in flight — drives the
    /// disabled state + label of the ••• popover row.
    @Published var isAIRenaming: Bool = false
    @Published var dragOver: Bool = false
    @Published var lastExportFolder: URL? = nil
    @Published var toast: Toast? = nil
    private var toastDismissTask: Task<Void, Never>?
    /// Held so the batch Squish operation can be cancelled (e.g. when the
    /// user clears all items mid-processing).
    var processingTask: Task<Void, Never>?

    /// Combine subscriptions forwarding each ImageItem's `objectWillChange`
    /// to ours. SwiftUI views that observe AppState (e.g. BottomBar) don't
    /// automatically re-render when a per-item @Published changes — without
    /// this bridge the pending badge wouldn't refresh after a rotate / crop
    /// / processed-data update on an item.
    private var itemCancellables: [UUID: AnyCancellable] = [:]

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

    /// Build the ProcessOptions that *would* be applied to `item` right now,
    /// given the current global settings + the item's per-instance edits.
    /// Used both by processOne() and by needsProcessing(_:) to compare against
    /// the snapshot taken at the last successful squish.
    func currentOptions(for item: ImageItem) -> ProcessOptions {
        ProcessOptions(
            format: outputFormat,
            quality: quality,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            stripMetadata: stripMetadata,
            rotationDegrees: item.rotationDegrees,
            flipHorizontal: item.flipHorizontal,
            cropRectNormalized: item.cropRectNormalized,
            removeBackground: item.removeBackground,
            itemID: item.id
        )
    }

    /// An item is "pending" if it has never been squished OR if any of the
    /// settings that affect the output have changed since the last squish.
    /// This is what drives the Squish/Save button switch and the badge count.
    func needsProcessing(_ item: ImageItem) -> Bool {
        guard item.processedData != nil,
              let last = item.lastProcessedOptions else { return true }
        return last != currentOptions(for: item)
    }

    var pendingItems: [ImageItem] {
        items.filter { needsProcessing($0) }
    }

    var pendingCount: Int { pendingItems.count }
    var hasPending: Bool { !pendingItems.isEmpty }

    /// Accepts any mix of file and folder URLs. Folders are expanded
    /// recursively. Image files are added directly; PDFs are rendered
    /// page-by-page to temp PNGs and each page becomes its own item.
    func addItems(from urls: [URL]) {
        let resolved = Self.resolveImageURLs(urls)
        var freshlyAdded: [ImageItem] = []

        // Split images vs PDFs — images go straight in, PDFs need an
        // async render pass before their pages can join the grid.
        let pdfs = resolved.filter { $0.pathExtension.lowercased() == "pdf" }
        let imageURLs = resolved.filter { $0.pathExtension.lowercased() != "pdf" }

        // -- Image path (fast, sync) -----------------------------------
        for url in imageURLs {
            if items.contains(where: { $0.sourceURL == url }) { continue }
            if let item = ImageItem(url: url) {
                items.append(item)
                subscribeToItemChanges(item)
                Task { await loadThumbnail(for: item) }
                freshlyAdded.append(item)
            }
        }

        // -- PDF path (async — rendering pages takes ~50-100 ms each) --
        // Each PDF kicks off its own background render; pages get added
        // to the grid on the main actor when ready, complete with the
        // cascade animation (hasAppeared flag honours the same path).
        for pdfURL in pdfs {
            importPDF(pdfURL)
        }
        // Cascade-in animation: each new card flips its `hasAppeared`
        // flag with a small per-item delay so a batch drop of N images
        // visibly waterfalls in (instead of all materialising at once).
        // We cap the stagger at 10 items so a 50-image drop doesn't take
        // ~2 s to finish; items beyond the cap come in together at the
        // last delay slot, which still looks great.
        let staggerStep: TimeInterval = 0.028
        let staggerCap: Int = 8
        for (idx, item) in freshlyAdded.enumerated() {
            let slot = min(idx, staggerCap)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(slot) * staggerStep) { [weak item] in
                item?.hasAppeared = true
            }
        }
        scheduleEstimates()
    }

    /// Renders a PDF off the main thread (it's CPU-bound, ~50-100 ms /
    /// page at 150 DPI), then hops back to MainActor to add each page
    /// as a regular ImageItem so the rest of the pipeline — compress,
    /// rename, save — treats them exactly like dropped JPEGs.
    private func importPDF(_ pdfURL: URL) {
        // Surface what's happening: a 30-page PDF can take a couple of
        // seconds before any card appears. A toast gives users feedback
        // and auto-dismisses; it's replaced by the success path when
        // rendering completes.
        showToast(.success(
            "Importing \(pdfURL.lastPathComponent)…",
            icon: "doc.text",
            duration: 30  // long-lived; will be replaced on completion
        ))

        // Task (not Task.detached) inherits AppState's MainActor isolation;
        // only the actual PDFKit work runs off-main via Task.detached, then
        // the result hops back to the actor automatically when awaited.
        // Cleaner Swift 6 concurrency story than capturing self into a
        // detached task and re-binding inside MainActor.run.
        Task { [weak self] in
            let pageURLs = await Task.detached(priority: .userInitiated) {
                PDFRenderer.renderPages(of: pdfURL)
            }.value
            guard let self else { return }
            self.absorbRenderedPages(pageURLs, from: pdfURL)
        }
    }

    /// Called on MainActor after a PDF finished rendering — wires each
    /// page into the same path a dropped image would take, including
    /// the staggered entrance animation.
    private func absorbRenderedPages(_ pageURLs: [URL], from pdfURL: URL) {
        guard !pageURLs.isEmpty else {
            // PDFKit returned 0 pages (corrupt file, encrypted, …) — tell
            // the user so they don't think we silently dropped the file.
            showToast(.success(
                "Couldn't import \(pdfURL.lastPathComponent)",
                icon: "exclamationmark.bubble"
            ))
            return
        }

        var added: [ImageItem] = []
        for url in pageURLs {
            if items.contains(where: { $0.sourceURL == url }) { continue }
            if let item = ImageItem(url: url) {
                items.append(item)
                subscribeToItemChanges(item)
                Task { await loadThumbnail(for: item) }
                added.append(item)
            }
        }

        // Use the same stagger as a normal drop so 12 pages cascade in.
        let step: TimeInterval = 0.028
        let cap: Int = 8
        for (idx, item) in added.enumerated() {
            let slot = min(idx, cap)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(slot) * step) { [weak item] in
                item?.hasAppeared = true
            }
        }
        scheduleEstimates()

        let plural = added.count > 1 ? "s" : ""
        showToast(.success("Imported \(added.count) page\(plural) from \(pdfURL.lastPathComponent)", icon: "doc.text"))
    }

    /// Bridge per-item @Published changes (rotation, crop, processedData…)
    /// to AppState's own objectWillChange so views observing AppState — most
    /// notably BottomBar — re-render on per-item updates. Held weakly to
    /// avoid retain cycles.
    private func subscribeToItemChanges(_ item: ImageItem) {
        itemCancellables[item.id] = item.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }

    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"
    ]

    private static let supportedDocumentExtensions: Set<String> = [
        "pdf"
    ]

    private static let allSupportedExtensions: Set<String> =
        supportedImageExtensions.union(supportedDocumentExtensions)

    /// Recursively expand any folder URLs, filter the file URLs by
    /// supported extension, but do NOT yet split images from PDFs —
    /// the caller decides what to do with each. Caller-side routing
    /// keeps this helper simple and reusable.
    private static func resolveImageURLs(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Recurse into the folder, picking up any supported file
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let sub as URL in enumerator {
                        if allSupportedExtensions.contains(sub.pathExtension.lowercased()) {
                            out.append(sub)
                        }
                    }
                }
            } else if allSupportedExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    func removeItem(_ item: ImageItem) {
        itemCancellables[item.id]?.cancel()
        itemCancellables.removeValue(forKey: item.id)
        cleanupTransientSource(for: item)
        // Release the cached Vision mask for this item (if any).
        // Each cached mask is ~3-8 MB; over a long session of editing
        // and removing dozens of images, this matters.
        BackgroundRemover.clearCache(for: item.id)
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        // If a batch Squish is currently running, abort it cleanly.
        processingTask?.cancel()
        processingTask = nil
        estimateTask?.cancel()
        estimateTask = nil
        itemCancellables.values.forEach { $0.cancel() }
        itemCancellables.removeAll()
        for item in items { cleanupTransientSource(for: item) }
        // One-shot purge of every cached mask in this session.
        BackgroundRemover.clearAllCache()
        items.removeAll()
    }

    /// PDF imports render each page into a temp PNG on disk. When the
    /// item leaves the grid (single removal or Clear all) the file is
    /// no longer needed — delete it so /tmp doesn't accumulate cruft
    /// across long sessions. Non-PDF sources are untouched: those are
    /// the user's original files.
    private func cleanupTransientSource(for item: ImageItem) {
        let url = item.sourceURL
        guard PDFRenderer.isRenderedPageURL(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - AI rename (Apple Vision, on-device)

    /// Walk every imported image, run on-device classification, and set
    /// `customBaseName` on each item to a clean, content-derived name.
    ///
    /// Behaviour:
    /// - Runs requests in parallel (TaskGroup) — Vision is GPU-bound on
    ///   Apple Silicon so a small concurrency cap keeps the UI snappy
    ///   without saturating the ANE.
    /// - Each item's `aiRenaming` flag flips on while its request is in
    ///   flight, so the card can show a per-item spinner.
    /// - Collisions are de-duplicated by appending `-2`, `-3`, … in the
    ///   order images were imported (stable, no reordering surprises).
    /// - Images for which classification returns no usable label are
    ///   left with their previous name. We never silently set a generic
    ///   fallback like "image" — better to keep the original filename
    ///   than to give the user a useless one.
    func renameAllWithAI() {
        guard !isAIRenaming, !items.isEmpty else { return }
        isAIRenaming = true

        // Snapshot the items + URLs up front so list mutations during the
        // batch (drag-and-drop a new file) don't race with the rename.
        let snapshot = items
        for item in snapshot { item.aiRenaming = true }

        Task { [weak self] in
            // Run classifications in small concurrent chunks. Apple Vision
            // is GPU/ANE-bound; 4 in flight is the sweet spot on M-series —
            // any more and we waste memory queueing for the same ANE.
            // Chunking keeps that simple without pulling in a semaphore.
            var suggestions: [UUID: String] = [:]
            let chunkSize = 4
            var index = 0
            while index < snapshot.count {
                let end = min(index + chunkSize, snapshot.count)
                let chunk = Array(snapshot[index..<end])
                await withTaskGroup(of: (UUID, String?).self) { group in
                    for item in chunk {
                        group.addTask {
                            let name = await AIRenamer.suggestName(for: item.sourceURL)
                            return (item.id, name)
                        }
                    }
                    for await (id, name) in group {
                        if let name { suggestions[id] = name }
                    }
                }
                // Flip the per-item spinner OFF for this chunk as soon as
                // it's done — gives the user visual progress instead of
                // an all-or-nothing wait.
                await MainActor.run {
                    for item in chunk { item.aiRenaming = false }
                }
                index = end
            }

            await MainActor.run {
                guard let self else { return }

                // Apply names in import order so collision suffixes are
                // assigned predictably (1st `dog`, 2nd `dog-2`, …).
                var usedNames = Set<String>()
                var renamedCount = 0

                for item in snapshot {
                    // Spinners were already cleared chunk-by-chunk above;
                    // this is a no-op guard in case a chunk was skipped.
                    if item.aiRenaming { item.aiRenaming = false }
                    guard let candidate = suggestions[item.id] else { continue }

                    let unique = self.uniqueName(candidate, existing: &usedNames)
                    if item.customBaseName != unique {
                        item.customBaseName = unique
                        renamedCount += 1
                    } else {
                        // Even if unchanged, claim the name so subsequent
                        // items don't collide on it.
                        usedNames.insert(unique)
                    }
                }

                self.isAIRenaming = false

                guard renamedCount > 0 else {
                    self.showToast(.success("No new names suggested", icon: "wand.and.stars"))
                    return
                }
                let plural = renamedCount > 1 ? "s" : ""
                self.showToast(.success("\(renamedCount) image\(plural) renamed by AI", icon: "wand.and.stars"))
            }
        }
    }

    /// Single-image variant of renameAllWithAI — triggered by the ✨
    /// button in the editor header. Runs Vision on just this item and
    /// applies the suggested name, falling back to a toast notification
    /// if the classifier can't produce anything usable.
    func renameWithAI(_ item: ImageItem) {
        guard !item.aiRenaming else { return }
        item.aiRenaming = true

        Task { [weak self] in
            let suggestion = await AIRenamer.suggestName(for: item.sourceURL)
            await MainActor.run {
                guard let self else { return }
                item.aiRenaming = false

                guard let suggestion else {
                    // Vision couldn't classify with sufficient confidence —
                    // tell the user instead of silently doing nothing.
                    self.showToast(.success(
                        "Couldn't suggest a name for this image",
                        icon: "exclamationmark.bubble"
                    ))
                    return
                }

                // De-duplicate against every OTHER item's current name so
                // two cards don't end up identical. Excluding `item` itself
                // means re-running on the same image is idempotent (no
                // pointless "-2" suffix appears just because the previous
                // value happened to match the new suggestion).
                var existing = Set<String>(
                    self.items.compactMap { $0.id == item.id ? nil : $0.customBaseName }
                )
                let unique = self.uniqueName(suggestion, existing: &existing)

                guard unique != item.customBaseName else { return }
                item.customBaseName = unique
            }
        }
    }

    /// De-duplicate a candidate name against the set of already-claimed
    /// names. First occurrence keeps the bare name; subsequent collisions
    /// get `-2`, `-3`, … suffixed. The set is mutated to track the choice.
    private func uniqueName(_ candidate: String, existing: inout Set<String>) -> String {
        if !existing.contains(candidate) {
            existing.insert(candidate)
            return candidate
        }
        var n = 2
        while true {
            let attempt = "\(candidate)-\(n)"
            if !existing.contains(attempt) {
                existing.insert(attempt)
                return attempt
            }
            n += 1
        }
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
        // Use currentOptions(for:) — it includes removeBackground + itemID
        // which makeEditedThumbnail needs to apply the cached Vision mask.
        // The previous hand-rolled ProcessOptions here forgot those two
        // fields, so after Apply the card kept showing the full image.
        let opts = currentOptions(for: item)
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
