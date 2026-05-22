import SwiftUI
import AppKit

/// Floating banner that auto-dismisses. Sits just above the bottom bar.
struct ToastView: View {
    let toast: Toast
    let onAction: () -> Void
    let onDismiss: () -> Void

    @State private var hoveringAction = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.success)

            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            if let label = toast.actionLabel {
                Divider()
                    .frame(height: 14)
                    .opacity(0.4)
                Button(action: { onAction() }) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .underline(hoveringAction, color: Theme.accent)
                }
                .buttonStyle(.plain)
                .onHover { hoveringAction = $0; updateCursor($0) }
            }

            // Subtle close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.leading, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 6)
    }
}
