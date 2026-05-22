import SwiftUI
import AppKit

struct TopToolbar: View {
    @EnvironmentObject var state: AppState
    var openFiles: () -> Void

    @State private var morePopover = false

    var body: some View {
        // Main modification controls in the geometric centre. The "Add images"
        // and "More options" buttons sit on the leading / trailing edges via
        // overlays so they don't affect the centering math.
        HStack(spacing: 10) {
            FormatPill()

            WHPill()

            QualityPill(value: $state.quality,
                        disabled: !state.outputFormat.supportsQuality)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            IconPillButton(symbol: "photo.badge.plus", help: "Add images") {
                openFiles()
            }
            .padding(.leading, 24)
        }
        .overlay(alignment: .trailing) {
            IconPillButton(symbol: "ellipsis", help: "More options") {
                morePopover.toggle()
            }
            .popover(isPresented: $morePopover, arrowEdge: .bottom) {
                MoreOptionsPopover()
                    .environmentObject(state)
            }
            .padding(.trailing, 24)
        }
        // Top padding must keep controls outside the macOS title-bar drag zone
        // (~28pt) AND leave a 24pt gap below the section divider drawn at y=32.
        .padding(.top, Theme.Spacing.titleBarSafe)
        .padding(.bottom, 0)
        // toolbarBg = windowBg so the toolbar visually merges with the body
        // (no bottom divider = controls feel like they live inside the same
        // canvas as the placeholder / image grid below).
        .background(Theme.toolbarBg)
        // Visual separator BETWEEN the macOS title-bar drag zone (top 28pt)
        // and the controls area below
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.5)
                .offset(y: 32)
        }
    }
}

// MARK: - Format pill (custom Button + popover for reliable glass rendering)
// Reason: SwiftUI's Menu with .borderlessButton strips custom background modifiers
// on its label, so we drive the dropdown ourselves with a popover.
struct FormatPill: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.pillContent(active: false))

                Text(state.outputFormat.rawValue.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.pillContent(active: false))
                    .tracking(0.2)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.pillContent(active: false).opacity(hovering ? 0.80 : 0.55))
                    .padding(.leading, 1)
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.pillHeight)
            .glassPill(active: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0; updateCursor($0) }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(OutputFormat.allCases) { f in
                    FormatOption(format: f, selected: state.outputFormat == f) {
                        state.outputFormat = f
                        isOpen = false
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 180)
        }
    }
}

// Single row in the format popover
struct FormatOption: View {
    let format: OutputFormat
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Theme.accent : Theme.strokeStrong, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if selected {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(format.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if let ext = format.fileExtension.isEmpty ? nil : format.fileExtension.uppercased() {
                    Text(".\(ext)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; updateCursor($0) }
    }
}

// MARK: - W / H combined pill (segmented, single capsule)
struct WHPill: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            DimensionHalf(label: "W", value: $state.targetWidth)

            // Vertical divider — visible on both blue (active) and gray (inactive) backgrounds, both modes
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)

            DimensionHalf(label: "H", value: $state.targetHeight)
        }
        .frame(height: Theme.pillHeight)
        .clipShape(Capsule(style: .continuous))
    }
}

// One side of the W/H pill — direct binding to the AppState dimension, no
// auto-propagation. When only one of W/H is filled the pipeline does a
// proportional resize; when both are filled it switches to scale-to-fill
// + center crop to exact W × H.
struct DimensionHalf: View {
    let label: String
    @Binding var value: Int?

    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var text: String = ""

    var isActive: Bool { value != nil || focused }

    /// Adaptive width for the TextField, computed from text length.
    /// Roughly ~9pt per monospaced digit at 13pt + small padding,
    /// with a minimum of 2 characters' worth so even an empty/short input
    /// stays comfortably clickable.
    private var fieldWidth: CGFloat {
        let chars = max(text.count, 2)
        return CGFloat(chars) * 9 + 6
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()

            // No `prompt:` — the "px" lives EXTERNALLY below as a stable
            // suffix. Mixing a prompt (centered inside the field) with the
            // external suffix caused "px" to jump positions on focus or on
            // the first keystroke. With this layout "px" only shifts when
            // fieldWidth actually changes (i.e. the user types).
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .frame(width: fieldWidth)
                .foregroundStyle(Theme.pillContent(active: isActive))
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }

            // Always-visible "PX" suffix — same font size/weight as the W/H
            // label so they sit on the same visual line (HStack center
            // alignment becomes pixel-perfect when all text shares metrics).
            Text("PX")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.pillContentSecondary(active: isActive))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.pillHeight)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onHover { hovering = $0; updateCursor($0) }
        .onAppear { text = value.map { String($0) } ?? "" }
        // Always sync text with external value — covers proportional propagation
        // from the other half when the lock is active.
        .onChange(of: value) { _, new in
            text = new.map { String($0) } ?? ""
        }
        .animation(.easeInOut(duration: 0.18), value: fieldWidth)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    private var backgroundColor: Color {
        if isActive {
            return hovering ? Theme.accentHover : Theme.accent
        }
        return hovering ? Theme.surface3 : Theme.surface2
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
        } else if let n = Int(trimmed), n > 0 {
            value = n
        } else {
            // Invalid input — revert text to the existing value
            text = value.map { String($0) } ?? ""
        }
    }
}

// MARK: - Quality pill (inline slider — drag to set, no popover)
struct QualityPill: View {
    @Binding var value: Double
    var disabled: Bool = false

    @State private var hovering = false
    @State private var isDragging = false

    private let pillWidth: CGFloat = 200
    private let minQuality: Double = 0.10
    private let maxQuality: Double = 1.00

    var body: some View {
        ZStack(alignment: .leading) {
            // Track (full pill, gray)
            Capsule(style: .continuous)
                .fill(hovering && !disabled ? Theme.surface3 : Theme.surface2)

            // Filled portion (accent, sized to current value).
            // Rectangle gets clipped by the outer .clipShape(Capsule) to give
            // a rounded-left / sharp-right edge — classic progress-in-pill look.
            GeometryReader { geo in
                Rectangle()
                    .fill(fillColor)
                    .frame(width: max(0, geo.size.width * value))
            }
            .allowsHitTesting(false)

            // Labels on top of both layers
            HStack {
                Text("Quality")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .allowsHitTesting(false)
        }
        .frame(width: pillWidth, height: Theme.pillHeight)
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !disabled else { return }
                    isDragging = true
                    let raw = g.location.x / pillWidth
                    value = min(max(minQuality, raw), maxQuality)
                }
                .onEnded { _ in isDragging = false }
        )
        .onHover { hovering = $0; if !disabled { updateCursor($0) } }
        .opacity(disabled ? 0.5 : 1.0)
        .animation(.easeOut(duration: 0.10), value: hovering)
        .help(disabled ? "Quality is locked for PNG (lossless)" : "Drag to adjust quality")
    }

    private var fillColor: Color {
        if isDragging { return Theme.accentPress }
        if hovering   { return Theme.accentHover }
        return Theme.accent
    }
}

// MARK: - Icon pill (generic, flat)
struct IconPillButton: View {
    let symbol: String
    let help: String
    var disabled: Bool = false
    var active: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
                .foregroundStyle(Theme.pillContent(active: active))
                .padding(.horizontal, 11)
                .frame(height: Theme.pillHeight)
                .glassPill(active: active, hovering: hovering && !disabled)
                .opacity(disabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hovering = $0; if !disabled { updateCursor($0) } }
    }
}

// MARK: - More options popover
struct MoreOptionsPopover: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: state.isDarkMode ? "moon.fill" : "sun.max.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dark mode")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(state.isDarkMode ? "Currently on" : "Currently off")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $state.isDarkMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Strip metadata")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("Remove EXIF + GPS data")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $state.stripMetadata)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-check for updates")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("Daily, via Sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $updater.automaticallyChecks)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider()

            HStack {
                Text("About Squish")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("v\(updater.currentVersion)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct HoverPopoverButton: View {
    let symbol: String
    let label: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(disabled ? Theme.textTertiary : Theme.accent)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(disabled ? Theme.textTertiary : Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && !disabled ? Theme.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0; if !disabled { updateCursor($0) } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Cursor helper
func updateCursor(_ hovering: Bool) {
    if hovering {
        NSCursor.pointingHand.set()
    } else {
        NSCursor.arrow.set()
    }
}
