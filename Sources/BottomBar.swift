import SwiftUI
import AppKit

struct BottomBar: View {
    @EnvironmentObject var state: AppState
    var processAll: () -> Void
    var saveAll: () -> Void
    var addFolder: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left container — takes exactly half the remaining horizontal
            // space (mirroring the right one) so the centre item lands at the
            // exact pixel center of the bar regardless of button widths.
            HStack(spacing: 0) {
                TextActionButton(label: "Clear",
                                 symbol: "xmark.circle",
                                 disabled: state.items.isEmpty) {
                    withAnimation { state.clearAll() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)

            // Center: primary action (intrinsic width, perfectly centered)
            primaryAction

            // Right container — symmetrical to the left
            HStack(spacing: 0) {
                Spacer()
                TextActionButton(label: "Add folder",
                                 symbol: "folder.badge.plus",
                                 trailing: true) {
                    addFolder()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        // Solid color — see TopToolbar comment for rationale (avoids
        // material-blur flicker on card hover).
        .background(Theme.toolbarBg)
    }

    @ViewBuilder
    private var primaryAction: some View {
        // Show the pending-item count next to Squish only (not after processing).
        // A matching invisible badge on the LEFT keeps the button itself
        // pixel-perfectly centered inside the bottom bar.
        let showCount = !state.anyProcessed && !state.items.isEmpty
        HStack(spacing: 10) {
            if showCount {
                CountBadge(count: state.items.count).opacity(0).allowsHitTesting(false)
            }
            primaryButton
            if showCount {
                CountBadge(count: state.items.count)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if state.anyProcessed && !state.isProcessing {
            BigPillButton(symbol: "square.and.arrow.down",
                          label: "Save",
                          enabled: true,
                          loading: false) {
                saveAll()
            }
        } else {
            BigPillButton(symbol: state.isProcessing ? "circle.dotted" : "squish-logo",
                          label: state.isProcessing ? "Squishing…" : "Squish",
                          enabled: !state.items.isEmpty && !state.isProcessing,
                          loading: state.isProcessing) {
                processAll()
            }
        }
    }
}

/// Small pill showing the pending image count next to the Squish CTA.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.surface2)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.5)
            )
    }
}

// MARK: Big primary pill (center action) — flat Apple style
struct BigPillButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let loading: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if symbol == "squish-logo", let logo = Image.squishLogo() {
                    // Custom brand logo (template-tinted by foregroundStyle below)
                    logo
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        // Optical centering: square.and.arrow.down sits below the
                        // text's optical centre when aligned geometrically — its
                        // bounding box includes the upward arrow which adds top
                        // mass. Nudge the symbol up by 1pt to align with "Save".
                        .offset(y: -1)
                }
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 36)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0; if enabled { updateCursor($0) } }
        .pressAction(onPress: { pressed = true }, onRelease: { pressed = false })
        .keyboardShortcut(.return, modifiers: .command)
    }

    /// Keep the brand-blue family even when disabled, just with reduced opacity
    /// so the white label remains legible in both dark and light mode.
    private var fill: Color {
        guard enabled else { return Theme.accent.opacity(0.35) }
        if pressed { return Theme.accentPress }
        if hovering { return Theme.accentHover }
        return Theme.accent
    }
}

// MARK: side text-action buttons (Clear / Images)
struct TextActionButton: View {
    let label: String
    let symbol: String
    var disabled: Bool = false
    var trailing: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !trailing {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if trailing {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(hovering && !disabled ? Theme.textPrimary : Theme.textSecondary.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering && !disabled ? Theme.surface2 : Color.clear)
            )
            .opacity(disabled ? 0.4 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0; if !disabled { updateCursor($0) } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: press gesture helper
extension View {
    func pressAction(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }
}
