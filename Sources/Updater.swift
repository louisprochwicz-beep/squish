import Foundation
import SwiftUI
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI views can observe its state
/// and trigger update checks. Backed by `SPUStandardUpdaterController` which
/// brings the native Sparkle UI (popup, progress, install + relaunch).
@MainActor
final class UpdaterViewModel: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates: Bool = false
    @Published var automaticallyChecks: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    init() {
        // startingUpdater: true → start the updater right away
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.automaticallyChecks = controller.updater.automaticallyChecksForUpdates

        // Observe updater readiness
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "(not configured)"
    }
}
