import SwiftUI
import AppKit

@main
struct SquishApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdaterViewModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        Self.installClickOutsideToDefocus()
        // Pre-load the Vision foreground-mask model in the background so
        // the user's first "Remove background" click in the editor pays
        // 0 ms of model init cost. ~200 ms of background work.
        BackgroundRemover.warmUp()
    }

    /// Stored token so we can de-register the monitor if `installClickOutsideToDefocus`
    /// is somehow called twice (e.g. dynamic reload during development). Without
    /// this, repeated installs would stack handlers and leak.
    private static var clickMonitorToken: Any?

    /// Installs a global left-mouse-down monitor that resigns first-responder
    /// status whenever the user clicks outside of an NSTextField/NSTextView.
    /// SwiftUI on macOS keeps TextFields focused indefinitely otherwise, which
    /// can lead to surprising state when the user thinks they've "deselected".
    private static func installClickOutsideToDefocus() {
        // De-register any previously installed monitor before adding a new one.
        if let existing = clickMonitorToken {
            NSEvent.removeMonitor(existing)
            clickMonitorToken = nil
        }
        clickMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Only act if a text input is currently focused. We track the
            // OWNING NSTextField (the field editor's delegate), not the field
            // editor itself — because the editor is a singleton per window
            // reused across all fields, while the delegate identifies which
            // specific field is focused.
            guard let window = NSApp.keyWindow,
                  let editor = window.firstResponder as? NSText else { return event }
            let originalDelegate = editor.delegate as AnyObject?

            // If the click already lands directly on a text input, do nothing.
            let clickPoint = event.locationInWindow
            var view: NSView? = window.contentView?.hitTest(clickPoint)
            while let v = view {
                if v is NSTextField || v is NSTextView {
                    return event
                }
                view = v.superview
            }

            // The hit-test may have missed a SwiftUI TextField (the click can
            // land on a sibling label / padding area whose `onTapGesture`
            // forwards focus to the field via @FocusState). Defer the defocus
            // check across TWO runloop ticks — single `async` can run BEFORE
            // SwiftUI propagates @FocusState changes to the underlying
            // NSTextField, causing W → H transitions to lose focus mid-cycle.
            // Double-dispatch guarantees SwiftUI's view-update + first-responder
            // assignment have completed before we sample the responder.
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    guard let currentEditor = window.firstResponder as? NSText else { return }
                    let currentDelegate = currentEditor.delegate as AnyObject?
                    if originalDelegate === currentDelegate {
                        window.makeFirstResponder(nil)
                    }
                }
            }
            return event
        }
    }

    var body: some Scene {
        Window("Squish", id: "main") {
            ContentView()
                .environmentObject(state)
                .environmentObject(updater)
                // minHeight = 580 keeps the editor sheet (532pt) comfortably
                // centred with ~24pt scrim each side. Going lower would
                // start to crowd the modal against the window edges.
                .frame(minWidth: 740, minHeight: 580)
                .preferredColorScheme(state.isDarkMode ? .dark : .light)
                .background(WindowAccessor { window in
                    window.titlebarAppearsTransparent = true
                    window.isMovableByWindowBackground = false
                    window.titleVisibility = .hidden
                    window.styleMask.insert(.fullSizeContentView)
                    window.backgroundColor = .clear
                    window.appearance = NSAppearance(named: state.isDarkMode ? .darkAqua : .aqua)
                    // Don't auto-focus any TextField on launch — neutral state
                    window.initialFirstResponder = nil
                    DispatchQueue.main.async {
                        window.makeFirstResponder(nil)
                    }
                })
                .onChange(of: state.isDarkMode) { _, dark in
                    // React when the user flips the toggle — apply across all
                    // open windows so traffic lights / title chrome follow.
                    for window in NSApp.windows {
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    }
                }
                // External file opens: Finder "Open with > Squish", drag onto
                // the Dock icon, or `open -a Squish image.png` from CLI.
                // CFBundleDocumentTypes in Info.plist already makes us a
                // registered handler for public.image; .onOpenURL receives
                // the file and forwards it to the shared AppState.
                .onOpenURL { url in
                    state.addItems(from: [url])
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                .keyboardShortcut("u", modifiers: [.command])

                Divider()

                Button("Clear all") { state.clearAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(state.items.isEmpty)
            }
        }
    }
}

/// Bridge to mutate NSWindow once available
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { onWindow(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { onWindow(w) }
        }
    }
}
