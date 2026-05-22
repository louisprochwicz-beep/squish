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

            Text(state.dragOver ? "Drop to Squish" : "Import or drag your images")
                .font(.system(size: Theme.FontSize.h2, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: Theme.Anim.slower), value: state.dragOver)
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
        panel.allowedContentTypes = [.image]
        panel.begin { resp in
            guard resp == .OK else { return }
            onDrop(panel.urls)
        }
    }
}

