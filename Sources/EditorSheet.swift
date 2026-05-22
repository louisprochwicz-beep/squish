import SwiftUI
import AppKit

struct EditorSheet: View {
    @ObservedObject var item: ImageItem
    var onApply: () -> Void
    var onDismiss: () -> Void   // explicit dismiss so it works inside a custom overlay

    @State private var rotation: Int = 0
    @State private var flipH: Bool = false
    @State private var cropEnabled: Bool = false
    @State private var cropRect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            preview
                .padding(16)
                .frame(minHeight: 320)
            Divider().opacity(0.4)
            actionBar
        }
        .frame(width: 620, height: 532)
        .background(Theme.windowBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 10)
        .onAppear {
            rotation = item.rotationDegrees
            flipH = item.flipHorizontal
            if let r = item.cropRectNormalized {
                cropRect = r
                cropEnabled = true
            }
        }
    }

    private var header: some View {
        HStack {
            EditableFilenameField(item: item)
            Spacer()
            HoverCloseButton { onDismiss() }
        }
        .padding(16)
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.5)
                    )

                // Use the UNTOUCHED source thumbnail so we can apply the
                // current rotation/flip on top live. If we used item.thumbnail
                // (which already has the previously-applied edits baked in)
                // the transforms would double-up every time the editor reopens.
                if let img = item.sourceThumbnail ?? item.thumbnail {
                    let displayed = displayedImage(img)
                    let ratio = max(displayed.size.width / max(displayed.size.height, 1), 0.01)

                    // Image + CropOverlay share an EXPLICIT aspectRatio ZStack.
                    // This guarantees both fill the SAME area: the overlay's
                    // normalized coordinates (0..1) map directly to the image's
                    // pixel space, eliminating the letterboxing offset that
                    // caused Apply to produce a different crop than the preview.
                    ZStack {
                        Image(nsImage: displayed)
                            .resizable()
                        if cropEnabled {
                            CropOverlay(rect: $cropRect)
                        }
                    }
                    .aspectRatio(ratio, contentMode: .fit)
                    .padding(8)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func displayedImage(_ img: NSImage) -> NSImage {
        var out = img
        if rotation != 0 { out = out.rotated(by: CGFloat(rotation)) }
        if flipH { out = out.flippedHorizontally() }
        return out
    }

    // Single unified bottom bar: transform tools on the left, action buttons
    // on the right (Reset all → Cancel → Apply).
    private var actionBar: some View {
        HStack(spacing: 16) {
            // Transform tools: rotate, flip
            HStack(spacing: 6) {
                editButton("rotate.left", help: "Rotate -90°") {
                    rotation = (((rotation - 90) % 360) + 360) % 360
                }
                editButton("rotate.right", help: "Rotate 90°") {
                    rotation = ((rotation + 90) % 360 + 360) % 360
                }
                editButton(flipH ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                                  : "arrow.left.and.right.righttriangle.left.righttriangle.right",
                           help: "Flip horizontal",
                           active: flipH) {
                    flipH.toggle()
                }
            }

            Divider().frame(height: 22).opacity(0.5)

            // Crop tool + inline crop info when active
            HStack(spacing: 6) {
                editButton(cropEnabled ? "crop.rotate" : "crop",
                           help: "Crop", active: cropEnabled) {
                    cropEnabled.toggle()
                }
                if cropEnabled {
                    Text(String(format: "%.0f%% × %.0f%%", cropRect.width * 100, cropRect.height * 100))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                    Button("Reset") {
                        cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .pointerCursor()
                }
            }

            Spacer()

            // Right cluster: Reset all → Cancel → Apply
            Button("Reset all") {
                rotation = 0
                flipH = false
                cropEnabled = false
                cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .pointerCursor()

            SecondaryPill(label: "Cancel") { onDismiss() }
            PrimaryPill(label: "Apply") {
                item.rotationDegrees = rotation
                item.flipHorizontal = flipH
                item.cropRectNormalized = cropEnabled ? cropRect : nil
                onApply()
                onDismiss()
            }
        }
        .padding(16)
    }

    private func editButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        EditorIconButton(symbol: symbol, help: help, active: active, action: action)
    }
}

// MARK: - Inline-editable filename in the editor header
//
// Behaviour:
//   • idle  → displays the filename as plain text
//   • hover → a subtle gray "chip" background appears and a small pencil
//             icon fades in to signal that the name is clickable
//   • click → swaps to a TextField with the basename pre-loaded and the
//             field auto-focused. The source extension stays visible to
//             the right of the field (greyed) so the user knows what
//             they're editing — Squish never renames the original file.
//   • Enter / blur → commits a non-empty value to item.customBaseName,
//                    sanitising any path-separator characters that would
//                    break the eventual export filename.
//   • Esc → cancels and reverts to the previous value.
//
// We don't modify the on-disk source; customBaseName only changes what
// the editor + card show and what the exported file is named.
struct EditableFilenameField: View {
    @ObservedObject var item: ImageItem

    @State private var isEditing = false
    @State private var draft: String = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // The editable basename + (always-visible, non-editable) extension.
            // Wrapping both in the same HStack keeps them on one baseline and
            // prevents the layout from jumping when toggling edit mode.
            HStack(spacing: 0) {
                if isEditing {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focused)
                        .fixedSize()
                        .onSubmit { commit() }
                        // SwiftUI on macOS routes the Esc key through
                        // .onExitCommand — restores the previous value.
                        .onExitCommand { cancel() }
                        // Blur (click outside, switch field) also commits,
                        // matching macOS Finder rename behaviour.
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused && isEditing { commit() }
                        }
                } else {
                    Text(item.editableBaseName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !item.sourceExtension.isEmpty {
                    Text(".\(item.sourceExtension)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            // Pencil hint — fades in on hover only when not already editing,
            // so it doesn't compete with the active TextField for attention.
            if hovering && !isEditing {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        // A single tap anywhere on the chip area enters edit mode. We
        // skip the hit-test when the field is already focused so the
        // TextField itself receives clicks for cursor placement.
        .onTapGesture {
            if !isEditing { startEditing() }
        }
        .onHover { isHovering in
            hovering = isHovering
            if !isEditing { updateCursor(isHovering) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isEditing)
        .help(isEditing ? "Press Return to save, Escape to cancel" : "Click to rename")
    }

    private var backgroundFill: Color {
        if isEditing { return Theme.surface2 }
        return hovering ? Theme.surface2 : Color.clear
    }

    private func startEditing() {
        draft = item.editableBaseName
        isEditing = true
        // SwiftUI needs one runloop tick after the view reflows from
        // Text → TextField before focus can land on the new field.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty → leave the previous name untouched (we don't allow blanks).
        guard !trimmed.isEmpty else {
            isEditing = false
            return
        }
        // Strip filesystem-illegal characters so the eventual export path
        // is always writable. `/` and `:` are the two macOS will choke on.
        let sanitized = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // Treat re-typing the same name as a no-op (avoid an unnecessary
        // pending-options flip).
        if sanitized != item.editableBaseName {
            item.customBaseName = sanitized
        }
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }
}

// MARK: editor icon button (glass rounded-rect)
struct EditorIconButton: View {
    let symbol: String
    let help: String
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.pillContent(active: active))
                .frame(width: 34, height: 32)
                .glassRect(active: active, hovering: hovering, radius: 9)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0; updateCursor($0) }
    }
}

// MARK: footer pills (glass)
struct PrimaryPill: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .glassPill(active: true, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; updateCursor($0) }
        .keyboardShortcut(.return, modifiers: [])
    }
}

struct SecondaryPill: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.pillContent(active: false))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .glassPill(active: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; updateCursor($0) }
        .keyboardShortcut(.escape, modifiers: [])
    }
}

struct HoverCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.pillContent(active: false).opacity(hovering ? 1.0 : 0.7))
                .frame(width: 26, height: 26)
                .glassRect(active: false, hovering: hovering, radius: 13)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; updateCursor($0) }
    }
}

// MARK: - Cursor region (proper AppKit approach via addCursorRect)
//
// SwiftUI's .onHover + NSCursor.set() is unreliable on macOS: the system
// mouseMoved logic can reset the cursor between events. The robust pattern is
// to register a CursorRect on an NSView via -resetCursorRects + -addCursorRect.
// macOS then manages the cursor automatically while the mouse is in bounds.
private struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRegionNSView {
        let v = CursorRegionNSView()
        v.cursor = cursor
        return v
    }

    func updateNSView(_ nsView: CursorRegionNSView, context: Context) {
        if nsView.cursor !== cursor {
            nsView.cursor = cursor
        }
    }
}

private final class CursorRegionNSView: NSView {
    var cursor: NSCursor = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    // CRITICAL: don't capture any mouse events. The cursor-rect system and
    // the hit-test system are independent in AppKit — returning nil here
    // means the view stays "invisible" to clicks/drags (so SwiftUI's gesture
    // system receives them normally) while macOS still uses the registered
    // cursor rect to switch the cursor on hover.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

extension View {
    /// Registers an NSView-backed cursor region — macOS will automatically
    /// switch the cursor to `cursor` while the mouse is inside this view.
    func cursorRegion(_ cursor: NSCursor) -> some View {
        background(CursorRegion(cursor: cursor))
    }
}

// MARK: - Private cursors for diagonal corner resize
// macOS uses NW-SE and NE-SW diagonal cursors for window/frame resizing but
// doesn't expose them via the public NSCursor API. We access them via the
// Objective-C runtime — same approach used by Pixelmator, Affinity, Sketch.
private extension NSCursor {
    static var diagonalResizeNWSE: NSCursor {     // ↖↘
        privateCursor(named: "_windowResizeNorthWestSouthEastCursor") ?? .crosshair
    }
    static var diagonalResizeNESW: NSCursor {     // ↗↙
        privateCursor(named: "_windowResizeNorthEastSouthWestCursor") ?? .crosshair
    }
    private static func privateCursor(named selector: String) -> NSCursor? {
        let sel = NSSelectorFromString(selector)
        guard NSCursor.responds(to: sel) else { return nil }
        return NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor
    }
}

// MARK: Crop overlay — 8 handles, drift-free drag math, rule-of-thirds grid
struct CropOverlay: View {
    @Binding var rect: CGRect

    /// Rect snapshot captured at the start of a drag — every onChanged is
    /// computed from this snapshot + cumulative translation, which prevents
    /// the compounding drift the previous implementation had.
    @State private var dragStartRect: CGRect?

    private let minCropSize: CGFloat = 0.05    // 5 % of container minimum
    private let handleVisualSize: CGFloat = 12
    private let handleHitSize: CGFloat = 28    // larger invisible touch target
    private let edgeHandleLength: CGFloat = 28

    enum Handle: CaseIterable {
        case tl, t, tr, r, br, b, bl, l       // 4 corners + 4 edge midpoints
        var isCorner: Bool {
            switch self { case .tl, .tr, .br, .bl: return true; default: return false }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = CGRect(
                x: rect.minX * size.width,
                y: rect.minY * size.height,
                width: rect.width * size.width,
                height: rect.height * size.height
            )

            ZStack {
                // Dim mask outside the crop
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                // Rule-of-thirds grid inside the crop
                ruleOfThirds(frame: frame)

                // White border + body drag (moves the whole crop)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .contentShape(Rectangle())
                    .cursorRegion(.openHand)
                    .gesture(bodyDragGesture(container: size))

                // 8 handles (4 corners + 4 edges)
                ForEach(Handle.allCases, id: \.self) { h in
                    handleView(h, container: size, frame: frame)
                }
            }
        }
    }

    // MARK: rule of thirds (dashed)
    @ViewBuilder
    private func ruleOfThirds(frame: CGRect) -> some View {
        Path { p in
            let f = frame
            // 2 vertical lines
            p.move(to: CGPoint(x: f.minX + f.width / 3, y: f.minY))
            p.addLine(to: CGPoint(x: f.minX + f.width / 3, y: f.maxY))
            p.move(to: CGPoint(x: f.minX + 2 * f.width / 3, y: f.minY))
            p.addLine(to: CGPoint(x: f.minX + 2 * f.width / 3, y: f.maxY))
            // 2 horizontal lines
            p.move(to: CGPoint(x: f.minX, y: f.minY + f.height / 3))
            p.addLine(to: CGPoint(x: f.maxX, y: f.minY + f.height / 3))
            p.move(to: CGPoint(x: f.minX, y: f.minY + 2 * f.height / 3))
            p.addLine(to: CGPoint(x: f.maxX, y: f.minY + 2 * f.height / 3))
        }
        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    }

    // MARK: handles
    @ViewBuilder
    private func handleView(_ h: Handle, container: CGSize, frame: CGRect) -> some View {
        let pos = handlePosition(h, frame: frame)

        ZStack {
            // Invisible hit zone — generous, so the handle is easy to grab
            Color.clear
                .frame(width: handleHitSize, height: handleHitSize)
                .contentShape(Rectangle())

            // Visual marker
            if h.isCorner {
                Circle()
                    .fill(Theme.accent)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    .frame(width: handleVisualSize, height: handleVisualSize)
            } else {
                // Edge handle — short pill aligned along the edge
                let horizontal = (h == .t || h == .b)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Color.white, lineWidth: 1.5)
                    )
                    .frame(
                        width: horizontal ? edgeHandleLength : 6,
                        height: horizontal ? 6 : edgeHandleLength
                    )
            }
        }
        .position(pos)
        .cursorRegion(cursor(for: h))
        .gesture(handleDragGesture(h, container: container))
    }

    private func handlePosition(_ h: Handle, frame: CGRect) -> CGPoint {
        switch h {
        case .tl: return CGPoint(x: frame.minX, y: frame.minY)
        case .t:  return CGPoint(x: frame.midX, y: frame.minY)
        case .tr: return CGPoint(x: frame.maxX, y: frame.minY)
        case .r:  return CGPoint(x: frame.maxX, y: frame.midY)
        case .br: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .b:  return CGPoint(x: frame.midX, y: frame.maxY)
        case .bl: return CGPoint(x: frame.minX, y: frame.maxY)
        case .l:  return CGPoint(x: frame.minX, y: frame.midY)
        }
    }

    private func cursor(for h: Handle) -> NSCursor {
        switch h {
        case .tl, .br: return .diagonalResizeNWSE      // ↖↘ corner
        case .tr, .bl: return .diagonalResizeNESW      // ↗↙ corner
        case .t, .b:   return .resizeUpDown            // ↕ height
        case .l, .r:   return .resizeLeftRight         // ↔ width
        }
    }

    // MARK: drag gestures (snapshot-based math = no drift)
    private func bodyDragGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = rect }
                guard let start = dragStartRect else { return }
                let dx = value.translation.width / container.width
                let dy = value.translation.height / container.height
                let nx = min(max(0, start.minX + dx), 1 - start.width)
                let ny = min(max(0, start.minY + dy), 1 - start.height)
                rect = CGRect(origin: CGPoint(x: nx, y: ny), size: start.size)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func handleDragGesture(_ h: Handle, container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = rect }
                guard let start = dragStartRect else { return }
                let dx = value.translation.width / container.width
                let dy = value.translation.height / container.height
                rect = resizedRect(from: start, handle: h, dx: dx, dy: dy)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    /// Pure function — given a starting rect, a handle, and a delta in
    /// normalized container coords, returns the new rect clamped to bounds
    /// and respecting `minCropSize`.
    private func resizedRect(from start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch handle {
        case .tl:
            let nx = min(max(0, start.minX + dx), start.maxX - minCropSize)
            let ny = min(max(0, start.minY + dy), start.maxY - minCropSize)
            return CGRect(x: nx, y: ny, width: start.maxX - nx, height: start.maxY - ny)
        case .tr:
            let nw = min(max(minCropSize, start.width + dx), 1 - start.minX)
            let ny = min(max(0, start.minY + dy), start.maxY - minCropSize)
            return CGRect(x: start.minX, y: ny, width: nw, height: start.maxY - ny)
        case .br:
            let nw = min(max(minCropSize, start.width + dx), 1 - start.minX)
            let nh = min(max(minCropSize, start.height + dy), 1 - start.minY)
            return CGRect(x: start.minX, y: start.minY, width: nw, height: nh)
        case .bl:
            let nx = min(max(0, start.minX + dx), start.maxX - minCropSize)
            let nh = min(max(minCropSize, start.height + dy), 1 - start.minY)
            return CGRect(x: nx, y: start.minY, width: start.maxX - nx, height: nh)
        case .t:
            let ny = min(max(0, start.minY + dy), start.maxY - minCropSize)
            return CGRect(x: start.minX, y: ny, width: start.width, height: start.maxY - ny)
        case .r:
            let nw = min(max(minCropSize, start.width + dx), 1 - start.minX)
            return CGRect(x: start.minX, y: start.minY, width: nw, height: start.height)
        case .b:
            let nh = min(max(minCropSize, start.height + dy), 1 - start.minY)
            return CGRect(x: start.minX, y: start.minY, width: start.width, height: nh)
        case .l:
            let nx = min(max(0, start.minX + dx), start.maxX - minCropSize)
            return CGRect(x: nx, y: start.minY, width: start.maxX - nx, height: start.height)
        }
    }
}

// MARK: NSImage helpers (preview only)
extension NSImage {
    func rotated(by degrees: CGFloat) -> NSImage {
        let radians = degrees * .pi / 180
        let newSize: NSSize = {
            let s = size
            let absSin = abs(sin(radians)); let absCos = abs(cos(radians))
            return NSSize(width: s.width * absCos + s.height * absSin,
                          height: s.width * absSin + s.height * absCos)
        }()
        let out = NSImage(size: newSize)
        out.lockFocus()
        defer { out.unlockFocus() }
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        ctx?.rotate(by: radians)
        ctx?.translateBy(x: -size.width / 2, y: -size.height / 2)
        draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        return out
    }

    func flippedHorizontally() -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        defer { out.unlockFocus() }
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.translateBy(x: size.width, y: 0)
        ctx?.scaleBy(x: -1, y: 1)
        draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        return out
    }
}
