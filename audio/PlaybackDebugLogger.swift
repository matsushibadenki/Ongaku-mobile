import Foundation
import os

/// Xcode Console用の再生診断ログ。
/// Console.appでは subsystem = littlebuddha.audio、category = Playback で絞り込めます。
enum PlaybackDebugLogger {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "littlebuddha.audio",
        category: "Playback"
    )

    nonisolated static func event(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    nonisolated static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    nonisolated static func failure(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    nonisolated static func fileName(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? "<unknown>" : url.lastPathComponent
    }
}
