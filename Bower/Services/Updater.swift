import Foundation
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle's standard updater when the Sparkle module is linked. Builds made
/// without Sparkle keep the menu item and leave checking disabled.
@Observable
final class Updater {
    private(set) var canCheckForUpdates = false

#if canImport(Sparkle)
    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
#else
    func checkForUpdates() {}
#endif
}
