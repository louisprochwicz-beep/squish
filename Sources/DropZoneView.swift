import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DropZoneView: View {
    @EnvironmentObject var state: AppState
    var isCompact: Bool
    var onDrop: ([URL]) -> Void

    @State private var hover = false

    var body: some View {
        let active = state.dragOver || hover

        VStack(spacing: 20) {
            // Same icon in both idle and drag-over states — only the scale
            // changes for subtle visual feedback while dragging.
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: Theme.FontSize.icon, weight: .medium))
                .foregroundStyle(Theme.accent)
                .symbolRenderingMode(.monochrome)
                .scaleEffect(state.dragOver ? 1.12 : 1.0)
                .animation(Theme.Anim.dropZoneSpring, value: state.dragOver)

            // Title + small format hint stacked. Wrapped in their own
            // VStack so the inner gap (12pt) is independent of the
            // outer dropzone gap (20pt from the icon).
            VStack(spacing: 12) {
                Text(state.dragOver ? "Drop to Squish" : "Import or drag your images")
                    .font(.system(size: Theme.FontSize.h2, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: Theme.Anim.slower), value: state.dragOver)

                // Format hint — full coverage of every format Squish can
                // ingest. Middle-dot separator reads more "Apple native"
                // than commas. Slightly smaller font (11pt) keeps a long
                // 8-format list visually balanced under the title.
                // Fades out during dragOver so the "Drop to Squish"
                // message owns the user's attention.
                Text("JPEG · PNG · WEBP · HEIC · GIF · TIFF · BMP · PDF")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.3)
                    .opacity(state.dragOver ? 0 : 1)
                    .animation(.easeInOut(duration: Theme.Anim.slower), value: state.dragOver)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.dropzoneRadius, style: .continuous)
                .fill(Theme.surface1.opacity(active ? 1.0 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.dropzoneRadius, style: .continuous)
                .strokeBorder(
                    state.dragOver ? Theme.accent : Theme.strokeStrong,
                    style: StrokeStyle(lineWidth: state.dragOver ? 2 : 1, dash: [9, 6])
                )
                .animation(.easeInOut(duration: Theme.Anim.slow), value: state.dragOver)
        )
        .contentShape(Rectangle())
        .onTapGesture { openPanel() }
        .onHover { hover = $0; updateCursor($0) }
        // Smooth fade of the surface opacity when entering / leaving hover.
        .animation(.easeInOut(duration: Theme.Anim.slower), value: hover)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Accept any image format plus PDF — matches what the drop-zone
        // and the format hint advertise. Without `.pdf` here, users
        // could drag PDFs in but couldn't pick them via the panel.
        panel.allowedContentTypes = [.image, .pdf]
        panel.begin { resp in
            guard resp == .OK else { return }
            onDrop(panel.urls)
        }
    }
}

