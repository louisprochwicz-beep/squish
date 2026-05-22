import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var editingItem: ImageItem? = nil

    var body: some View {
        ZStack {
            // Window background — adapts to dark/light mode
            Theme.windowBg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TopToolbar(openFiles: openFilePicker)

                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                BottomBar(
                    processAll: processAll,
                    saveAll: saveAll,
                    addFolder: openFolderPicker
                )
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(
                    toast: toast,
                    onAction: {
                        if let url = toast.actionURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        state.dismissToast()
                    },
                    onDismiss: { state.dismissToast() }
                )
                .padding(.bottom, Theme.Spacing.toastBottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)           // re-fires transition on new toast
            }
        }
        .animation(Theme.Anim.toastSpring, value: state.toast)
        // Editor modal — implemented as a custom overlay (instead of .sheet)
        // so a click on the backdrop dismisses it, matching popover semantics.
        .overlay {
            if let item = editingItem {
                ZStack {
                    Theme.scrimDark45
                        .contentShape(Rectangle())
                        .onTapGesture { editingItem = nil }
                        .transition(.opacity)

                    EditorSheet(
                        item: item,
                        onApply: {
                            // 1. Rebuild the card preview with the new edits
                            state.reloadEditedThumbnail(for: item)
                            // 2. Recompute the live size estimate
                            state.scheduleEstimates()
                            // 3. If the image was already compressed, re-process
                            //    so processedBytes / processedPixelSize stay in sync
                            if item.processedBytes != nil {
                                Task { await processOne(item) }
                            }
                        },
                        onDismiss: { editingItem = nil }
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                // Ignore safe area on the WHOLE ZStack so it fills the full
                // window. Without this, the ZStack is inset by the title bar,
                // and the centered EditorSheet ends up ~14pt below true center.
                .ignoresSafeArea()
            }
        }
        .animation(Theme.Anim.modalSpring, value: editingItem != nil)
        .onDrop(of: [.fileURL], isTargeted: $state.dragOver) { providers in
            loadURLs(from: providers) { urls in
                state.addItems(from: urls)
            }
            return true
        }
        // Live size estimate — recompute predicted output bytes whenever a
        // setting that affects size changes. Debounced inside AppState.
        .onChange(of: state.quality)        { _, _ in state.scheduleEstimates() }
        .onChange(of: state.outputFormat)   { _, _ in state.scheduleEstimates() }
        .onChange(of: state.targetWidth)    { _, _ in state.scheduleEstimates() }
        .onChange(of: state.targetHeight)   { _, _ in state.scheduleEstimates() }
        .onChange(of: state.stripMetadata)  { _, _ in state.scheduleEstimates() }
        .overlay {
            if state.dragOver && !state.items.isEmpty {
                dropOverlay
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if state.items.isEmpty {
            DropZoneView(isCompact: false) { state.addItems(from: $0) }
                .padding(Theme.Spacing.lg)
        } else {
            ImageGridView(onEdit: { editingItem = $0 })
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Theme.scrimDark55
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text("Drop to add images")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Actions
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.begin { resp in
            guard resp == .OK else { return }
            state.addItems(from: panel.urls)
        }
    }

    private func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    private func processAll() {
        guard !state.isProcessing else { return }
        // Snapshot the set of items that need work RIGHT NOW. Anything
        // already up-to-date is left alone — see AppState.needsProcessing().
        let pending = state.pendingItems
        guard !pending.isEmpty else { return }

        // Record the "before" byte total for each pending item so the toast
        // can show a saving figure that reflects THIS batch only (not the
        // cumulative savings of every squish that's ever run on the items).
        let originalBytesThisBatch = pending.reduce(0) { $0 + $1.originalBytes }

        state.isProcessing = true
        state.processingTask?.cancel()
        state.processingTask = Task {
            var processedThisBatch: [ImageItem] = []
            for item in pending {
                if Task.isCancelled { break }
                let ok = await processOne(item)
                if ok { processedThisBatch.append(item) }
            }
            state.isProcessing = false
            state.processingTask = nil
            if Task.isCancelled { return }

            guard !processedThisBatch.isEmpty else { return }
            let processedBytesThisBatch = processedThisBatch.reduce(0) { $0 + ($1.processedBytes ?? 0) }
            let saved = max(0, originalBytesThisBatch - processedBytesThisBatch)
            let count = processedThisBatch.count
            let plural = count > 1 ? "s" : ""
            let savedStr = Theme.formatBytes(saved)
            state.showToast(.success("\(count) image\(plural) squished · saved \(savedStr)"))
        }
    }

    /// Returns true if the item was successfully (re-)processed.
    private func processOne(_ item: ImageItem) async -> Bool {
        item.status = .processing
        let opts = state.currentOptions(for: item)
        let url = item.sourceURL
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ImageProcessor.process(url: url, options: opts)
            }.value
            item.processedData = result.data
            item.processedBytes = result.data.count
            item.processedExtension = result.ext
            item.processedPixelSize = result.pixelSize
            // Stamp the snapshot LAST so needsProcessing() flips to "false"
            // only after every other field is in place.
            item.lastProcessedOptions = opts
            item.status = .done
            return true
        } catch {
            item.status = .failed(error.localizedDescription)
            return false
        }
    }

    private func saveAll() {
        let processed = state.items.filter { $0.processedData != nil }
        guard !processed.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Choose a folder to export your images"
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            state.lastExportFolder = dir
            var savedCount = 0
            var failedCount = 0
            var firstWritten: URL?
            for item in processed {
                guard let data = item.processedData,
                      let ext = item.processedExtension else { continue }
                // Honour any user-supplied name from the editor's rename
                // field; fall back to the source file's basename.
                let base = item.editableBaseName
                var filename = "\(base)-squish.\(ext)"
                var target = dir.appendingPathComponent(filename)
                var n = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    filename = "\(base)-squish-\(n).\(ext)"
                    target = dir.appendingPathComponent(filename)
                    n += 1
                }
                do {
                    try data.write(to: target, options: .atomic)
                    savedCount += 1
                    if firstWritten == nil { firstWritten = target }
                } catch {
                    failedCount += 1
                }
            }
            // Surface any failures via a toast so the user isn't left guessing.
            if savedCount > 0 {
                state.showToast(.exported(at: firstWritten ?? dir, count: savedCount))
            } else if failedCount > 0 {
                state.showToast(.success(
                    "Couldn't write any file — check folder permissions",
                    icon: "exclamationmark.triangle.fill",
                    duration: 6
                ))
            }
        }
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder — every image inside will be imported (subfolders included)."
        panel.prompt = "Import"
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            importFolder(dir)
        }
    }

    private func importFolder(_ dir: URL) {
        // AppState.addItems(from:) now recurses into folders by itself,
        // so we just hand the directory URL over.
        state.addItems(from: [dir])
    }
}
