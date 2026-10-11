@preconcurrency import AVFoundation
import AudioToolbox

/// Owns one render observer. It captures only the monitor, never the engine or UI.
/// Meter taps are delivered separately and are not a render scheduling clock.
nonisolated final class AudioRenderHeartbeat {
    private let unit: AUAudioUnit
    private let token: Int

    init(unit: AUAudioUnit, sampleRate: Double, monitor: AudioRenderHealthMonitor) {
        self.unit = unit
        token = unit.token(byAddingRenderObserver: { flags, _, frames, bus in
            // Audio Units notify both before and after rendering. Count each
            // cycle once, even if an implementation supplies both flags.
            guard bus == 0, flags.contains(.unitRenderAction_PreRender),
                  !flags.contains(.unitRenderAction_PostRender) else { return }
            monitor.recordRender(frameCount: frames, sampleRate: sampleRate)
        })
    }

    deinit { unit.removeRenderObserver(token) }
}
