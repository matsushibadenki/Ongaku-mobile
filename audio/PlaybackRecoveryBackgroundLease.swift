import UIKit

/// Request only the finite time needed to reactivate audio. This does not
/// keep a suspended app alive indefinitely or play silence in the background.
@MainActor
final class PlaybackRecoveryBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private(set) var expired = false

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Resume audio") { [weak self] in
            Task { @MainActor in
                self?.expired = true
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let identifier = identifier
        self.identifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
