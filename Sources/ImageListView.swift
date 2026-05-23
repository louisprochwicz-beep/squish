import SwiftUI
import AppKit

struct ImageGridView: View {
    @EnvironmentObject var state: AppState
    var onEdit: (ImageItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(state.items) { item in
                    // Insertion animation is driven PER ITEM via
                    // item.hasAppeared (scheduled in AppState.addItems
                    // with a small cascade delay). Using a per-item flag
                    // rather than a ForEach-level transition lets us
                    // stagger the cascade without re-animating existing
                    // cards every time a new one is added.
                    AppearingCard {
                        ImageCardView(item: item,
                                      onEdit: { onEdit(item) },
                                      onRemove: { state.removeItem(item) })
                    } visible: { item.hasAppeared }
                        // Removal animation — a tight, near-instant fade
                        // + slight shrink. Earlier this was a slow 0.35 s
                        // spring with bounce, which felt like clicking ×
                        // lagged. A snappier 0.20 s spring with almost
                        // no damping bounce reads as "instant" while
                        // still giving enough visual feedback that the
                        // user knows what they clicked is gone.
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.combined(with: .scale(scale: 0.85))
                        ))
                }
            }
            .padding(Theme.Spacing.lg)
            // Spring on the grid animates LAYOUT reflow when an item is
            // removed (neighbouring cards slide into the gap) AND drives
            // the .transition above. Tuned to ~200 ms response with
            // minimal bounce so removal feels immediate.
            .animation(.spring(response: 0.20, dampingFraction: 0.92), value: state.items.map(\.id))
        }
        .scrollIndicators(.automatic)
    }
}

struct ImageCardView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var item: ImageItem
    var onEdit: () -> Void
    var onRemove: () -> Void

    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Image background
            imageBackground

            // Top overlay : filename + hover actions
            VStack(spacing: 0) {
                topRow
                Spacer()
                bottomBadges
            }
            .padding(10)
        }
        .frame(height: 220)
        .background(Theme.surface1)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(hover ? Theme.accent : Theme.stroke, lineWidth: hover ? 1.5 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onHover { hover = $0; updateCursor($0) }
        .animation(.easeOut(duration: 0.15), value: hover)
        .onTapGesture(count: 2) { onEdit() }
    }

    // MARK: image bg
    private var imageBackground: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.surface2
                if let img = item.thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                // Bottom gradient for badge legibility
                LinearGradient(
                    colors: [.clear, Theme.scrimDark55],
                    startPoint: .center, endPoint: .bottom
                )
                // Top gradient for filename legibility
                LinearGradient(
                    colors: [Theme.scrimDark55, .clear],
                    startPoint: .top, endPoint: .center
                )
            }
        }
    }

    // MARK: top row (filename + hover actions)
    private var topRow: some View {
        HStack(alignment: .top) {
            // While the AI rename request is in flight for THIS item,
            // replace the filename with a mini spinner + "Naming…" so
            // the user has per-card progress feedback. The chip
            // dimensions stay close to the filename's so the card
            // doesn't visibly reflow.
            Group {
                if item.aiRenaming {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                        Text("Naming with AI…")
                    }
                } else {
                    Text(item.displayName)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(Theme.scrimDark55)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .strokeBorder(Theme.overlayLight10, lineWidth: 0.5)
            )
            .foregroundStyle(.white)

            Spacer(minLength: 6)

            if hover {
                HStack(spacing: 4) {
                    cardIcon("slider.horizontal.3", help: "Edit", action: onEdit)
                    cardIcon("xmark", help: "Remove", action: onRemove)
                }
                .transition(.opacity)
            } else {
                statusIndicator
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch item.status {
        case .pending: EmptyView()
        case .processing:
            ProgressView().controlSize(.small).scaleEffect(0.7)
                .padding(.trailing, 2)
        case .done:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.success)
                .padding(4)
                .background(Circle().fill(Theme.scrimDark45))
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.danger)
                .help(msg)
        }
    }

    private func cardIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverButton(symbol: symbol, help: help, action: action)
    }

    // MARK: bottom badges — format + dims on the left, size pushed to the right
    // alignment: .bottom makes the dims badge (single line) line up with the
    // "after" line of the format / size badges (two lines).
    private var bottomBadges: some View {
        HStack(alignment: .bottom, spacing: 6) {
            formatBadge
            dimsBadge
            Spacer(minLength: 8)
            sizeBadge
        }
    }

    private var formatBadge: some View {
        let fromExt = item.sourceURL.pathExtension.uppercased()
        let toExt: String?
        if let processed = item.processedExtension {
            toExt = processed.uppercased()
        } else {
            // Predicted target format (only shown if it differs from source)
            let target = (state.outputFormat == .keepOriginal)
                ? fromExt
                : state.outputFormat.fileExtension.uppercased()
            toExt = (target == fromExt) ? nil : target
        }
        return BadgeStack(top: fromExt, bottom: toExt, tint: toExt != nil ? .green : .neutral)
    }

    private var dimsBadge: some View {
        let srcDims = item.originalPixelSize.width > 0
            ? "\(Int(item.originalPixelSize.width))×\(Int(item.originalPixelSize.height))"
            : "—"
        let hasEdit = item.cropRectNormalized != nil
            || (item.rotationDegrees % 360) != 0
        let outDims: String?
        if let processed = item.processedPixelSize {
            outDims = "\(Int(processed.width))×\(Int(processed.height))"
        } else if item.originalPixelSize.width > 0,
                  (state.targetWidth != nil || state.targetHeight != nil || hasEdit) {
            // Predicted target dimensions — account for crop, rotation, resize
            let predicted = ImageProcessor.predictedSize(
                from: item.originalPixelSize,
                crop: item.cropRectNormalized,
                rotation: item.rotationDegrees,
                targetW: state.targetWidth,
                targetH: state.targetHeight
            )
            let label = "\(Int(predicted.width))×\(Int(predicted.height))"
            outDims = (label == srcDims) ? nil : label
        } else {
            outDims = nil
        }
        return BadgeStack(top: srcDims, bottom: outDims, tint: outDims != nil ? .green : .neutral)
    }

    private var sizeBadge: some View {
        let srcSize = Theme.formatBytes(item.originalBytes)
        let outSize: String?
        if let processed = item.processedBytes {
            outSize = Theme.formatBytes(processed)
        } else if let estimated = item.estimatedBytes {
            outSize = "~" + Theme.formatBytes(estimated)
        } else {
            outSize = nil
        }
        // Right-aligned so "3.7 MB" stacks on top of "~1.2 MB" against the right edge
        return BadgeStack(top: srcSize, bottom: outSize, tint: outSize != nil ? .green : .neutral, alignment: .trailing)
    }
}

// MARK: - Small per-card icon button with hover
struct HoverButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(hovering ? Theme.accent : Theme.scrimDark55)
                )
                .overlay(
                    Circle().strokeBorder(hovering ? .clear : Theme.overlayLight12, lineWidth: 0.5)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0; updateCursor($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Badge with top→bottom stacked values (before→after)
enum BadgeTint { case neutral, green }

struct BadgeStack: View {
    let top: String
    let bottom: String?
    let tint: BadgeTint
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(top)
                .strikethrough(bottom != nil, color: .white.opacity(0.5))
                .foregroundStyle(bottom != nil ? Color.white.opacity(0.55) : Color.white.opacity(0.85))
            if let bottom {
                Text(bottom)
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
            }
        }
        // SF (system) font + monospacedDigit so before/after rows of digits
        // (e.g. "153 KB" stacked over "~242 KB" or "1920×1080" rows) stay
        // aligned without the heavier code-style look of full .monospaced.
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.badgeRadius, style: .continuous)
                .fill(bottom != nil
                      ? Theme.success.opacity(0.85)
                      : Theme.scrimDark55)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.badgeRadius, style: .continuous)
                .strokeBorder(Theme.overlayLight10, lineWidth: 0.5)
        )
    }
}

// MARK: - Card entrance animation wrapper
//
// Drives the per-card "appear" animation off a Bool the parent passes in
// (typically `item.hasAppeared`). The card renders invisible + slightly
// shrunk on first paint; when the Bool flips to true (with a stagger
// scheduled in AppState.addItems) the card springs into place.
//
// Why a wrapper instead of attaching modifiers directly on ImageCardView:
//   1. Keeps the animation concerns in ONE place, easy to tweak.
//   2. Decouples the visual "appear" state from the card's own internal
//      state (hover, edit mode, etc.) so we never re-trigger entrance
//      animations on a re-render.
//   3. Plays nicely with the LazyVGrid's removal transition — the grid
//      sees the wrapper as a single child it can transition.
struct AppearingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let visible: () -> Bool

    var body: some View {
        content()
            .opacity(visible() ? 1 : 0)
            .scaleEffect(visible() ? 1 : 0.93)
            // Tuned to be just-perceptible: a tiny scale lift (7 %) +
            // opacity, on a snappy spring with minimal bounce. Total
            // perceived duration ≈ 250 ms so the card "lands" right
            // after the user releases their drop — quick enough to
            // feel responsive, slow enough that you register it.
            .animation(.spring(response: 0.30, dampingFraction: 0.88), value: visible())
    }
}
