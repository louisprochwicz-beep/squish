import SwiftUI
import AppKit

// MARK: Color helpers
private extension Color {
    init(hex: Int, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Adaptive color: picks light or dark hex based on the rendering NSAppearance.
private func dyn(light: Int, dark: Int, alpha: Double = 1.0) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let resolved = appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        let hex = (resolved == .darkAqua) ? dark : light
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }))
}

enum Theme {
    // MARK: Brand — Apple system blue (kept stable across modes for brand recognition)
    static let accent       = Color(hex: 0x0A84FF)
    static let accentHover  = Color(hex: 0x3994FF)
    static let accentPress  = Color(hex: 0x086EDC)
    static let accentSoft   = Color(hex: 0x0A84FF, alpha: 0.18)

    // MARK: Adaptive grays — Apple iOS palette, mirrored for light/dark
    static let gray  = dyn(light: 0x8E8E93, dark: 0x8E8E93)
    static let gray2 = dyn(light: 0xAEAEB2, dark: 0x636366)
    static let gray3 = dyn(light: 0xC7C7CC, dark: 0x48484A)
    static let gray4 = dyn(light: 0xD1D1D6, dark: 0x3A3A3C)
    static let gray5 = dyn(light: 0xE5E5EA, dark: 0x2C2C2E)
    static let gray6 = dyn(light: 0xF2F2F7, dark: 0x1C1C1E)

    // MARK: Semantic surfaces
    static let windowBg     = gray6
    static let toolbarBg    = gray6
    static let surface1     = gray5
    static let surface2     = gray5
    static let surface3     = gray4
    static let surface4     = gray3

    // MARK: Strokes (light → black tint, dark → white tint)
    static let stroke        = dyn(light: 0x000000, dark: 0xFFFFFF, alpha: 0.06)
    static let strokeStrong  = dyn(light: 0x000000, dark: 0xFFFFFF, alpha: 0.12)

    // MARK: Text — use system label colors that already adapt
    static let textPrimary   = Color(NSColor.labelColor)
    static let textSecondary = Color(NSColor.secondaryLabelColor)
    static let textTertiary  = Color(NSColor.tertiaryLabelColor)

    /// Text/icon color for content sitting inside a pill.
    /// - Active pill (accent fill): always white (good contrast on blue)
    /// - Inactive pill (gray fill): adaptive label color (white in dark, black in light)
    static func pillContent(active: Bool) -> Color {
        active ? .white : Color(NSColor.labelColor)
    }
    /// Secondary version (e.g. dimension label, helper text inside a pill).
    static func pillContentSecondary(active: Bool) -> Color {
        active ? Color.white.opacity(0.75) : Color(NSColor.secondaryLabelColor)
    }

    // MARK: Apple semantic colors
    static let success       = Color(hex: 0x30D158)
    static let successSoft   = Color(hex: 0x30D158, alpha: 0.20)
    static let danger        = Color(hex: 0xFF453A)
    static let warning       = Color(hex: 0xFF9F0A)

    // MARK: Overlays & scrims (semi-transparent layers)
    // Black tints used to dim content behind modals, dropzones, card gradients.
    static let scrimDark55   = Color.black.opacity(0.55)
    static let scrimDark45   = Color.black.opacity(0.45)
    static let scrimDark35   = Color.black.opacity(0.35)
    static let scrimDark30   = Color.black.opacity(0.30)
    // White tints used over images / accent backgrounds (always-dark contexts).
    static let overlayLight10 = Color.white.opacity(0.10)
    static let overlayLight12 = Color.white.opacity(0.12)
    static let overlayLight18 = Color.white.opacity(0.18)
    static let overlayLight35 = Color.white.opacity(0.35)

    // MARK: Sizing
    static let pillHeight: CGFloat = 32
    static let pillRadius: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let badgeRadius: CGFloat = 8
    static let modalRadius: CGFloat = 16
    static let dropzoneRadius: CGFloat = 22
    static let smallRadius: CGFloat = 6
    static let tinyRadius: CGFloat = 2

    // MARK: Spacing scale
    // Mostly multiples of 4 — keeps vertical / horizontal rhythm consistent.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let base: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 36

        /// Top padding of the unified toolbar — keeps controls outside the
        /// macOS title-bar drag zone (~28pt) with a comfortable gap.
        static let titleBarSafe: CGFloat = 56
        /// Bottom offset for the toast above the BottomBar.
        static let toastBottom: CGFloat = 76
    }

    // MARK: Typography sizes (raw point values for .font(.system(size:)))
    enum FontSize {
        static let caption: CGFloat = 9      // chevrons, tiny indicators
        static let small: CGFloat   = 10     // tiny labels
        static let badge: CGFloat   = 11     // card badge text, popover detail
        static let detail: CGFloat  = 12     // popover labels, secondary buttons
        static let base: CGFloat    = 13     // pills, controls — the workhorse
        static let lg: CGFloat      = 14     // bottom-bar primary action label
        static let h2: CGFloat      = 20     // dropzone heading
        static let icon: CGFloat    = 46     // dropzone hero icon
    }

    // MARK: Animation durations & springs (centralised so all UI ticks in sync)
    enum Anim {
        static let quick: Double  = 0.10     // active slider drag feedback
        static let snap: Double   = 0.12     // standard hover
        static let medium: Double = 0.15     // active state change
        static let slow: Double   = 0.18     // larger reflows (field width)
        static let slower: Double = 0.22     // text content + dropzone surface
        static let modal: Double  = 0.30     // editor sheet open/close
        // Springs — reused across grid insertions and toast / scale entries
        static let gridSpring: SwiftUI.Animation =
            .spring(response: 0.35, dampingFraction: 0.85)
        static let dropZoneSpring: SwiftUI.Animation =
            .spring(response: 0.35, dampingFraction: 0.70)
        static let modalSpring: SwiftUI.Animation =
            .spring(response: 0.30, dampingFraction: 0.85)
        static let toastSpring: SwiftUI.Animation =
            .spring(response: 0.42, dampingFraction: 0.82)
    }

    // MARK: helpers
    static func formatBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.includesUnit = true
        return f.string(fromByteCount: Int64(bytes))
    }

    static func percentSavings(original: Int, processed: Int) -> Double {
        guard original > 0 else { return 0 }
        return Double(original - processed) / Double(original) * 100.0
    }
}

// MARK: - Bundle SVG loader
extension Image {
    /// Loads the Squish brand logo SVG bundled in Resources/ as a template
    /// image — so its color follows the current `.foregroundStyle()`.
    /// macOS 14+ has native SVG rasterization in NSImage.
    static func squishLogo() -> Image? {
        guard let url = Bundle.main.url(forResource: "squish-logo", withExtension: "svg"),
              let nsImage = NSImage(contentsOf: url) else {
            return nil
        }
        nsImage.isTemplate = true
        return Image(nsImage: nsImage)
    }
}

// MARK: - Hover cursor
struct HoverCursor: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            hovering = isHovering
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func pointerCursor() -> some View { modifier(HoverCursor()) }
}

// MARK: - Flat pill (Apple style, adaptive)
struct GlassPill: ViewModifier {
    var active: Bool = false
    var hovering: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: active)
    }

    private var fillColor: Color {
        if active {
            return hovering ? Theme.accentHover : Theme.accent
        }
        return hovering ? Theme.surface3 : Theme.surface2
    }
}

struct GlassRect: ViewModifier {
    var active: Bool = false
    var hovering: Bool = false
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(fillColor))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: active)
    }

    private var fillColor: Color {
        if active {
            return hovering ? Theme.accentHover : Theme.accent
        }
        return hovering ? Theme.surface3 : Theme.surface2
    }
}

extension View {
    func glassPill(active: Bool = false, hovering: Bool = false) -> some View {
        self.modifier(GlassPill(active: active, hovering: hovering))
    }
    func glassRect(active: Bool = false, hovering: Bool = false, radius: CGFloat = 8) -> some View {
        self.modifier(GlassRect(active: active, hovering: hovering, radius: radius))
    }
}

// Legacy compat
extension View {
    func pillSurface(active: Bool) -> some View {
        self
            .frame(height: Theme.pillHeight)
            .padding(.horizontal, 14)
            .glassPill(active: active)
    }
}
