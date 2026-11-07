"""Run the shipping presentation preflight with task/timer boundaries isolated."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent.parent
source = (root / 'audio/AudioPlayerViewModel.swift').read_text()
view = (root / 'audio/ContentView.swift').read_text()
def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
binding = block(view, '    private var tabSelection: Binding<RootTab>')
assert binding.index('player.prepareForEffectsPresentation()') < binding.index('selectedTab = tab')
assert 'CustomTabBar(selectedTab: tabSelection,' in view
parts = ['''import Foundation
import CoreFoundation
@MainActor enum PlaybackDebugLogger { static func event(_ message: String) {} }
@MainActor final class ShippingEffectPresentation {
    enum Source { case local, system }
    var playbackSource: Source = .local
    var hasInitializedHiResPlaybackEngine = true
    var hasPreparedEffectsPresentation = false
    var isEffectScreenActive = false
    var qualityRecoveryNotBefore: TimeInterval = 0
    var systemAssetRecoveryTask: Task<Void, Never>?
    var precisionUpgradeTask: Task<Void, Never>?
    var preloadTrackTask: Task<Void, Never>?
    final class Engine { var isPlaying = true }
    let hiResPlaybackEngine = Engine()
    var isPlaying = false
    var systemQueueIndex: Int? = 0
    var resumedQuality = 0
    var resumedPreloads: [Int] = []
    func resumeAutomaticQualityUpgradeIfNeeded() { resumedQuality += 1 }
    func scheduleNextTrackPreload(after index: Int) { resumedPreloads.append(index) }
    var auditDelays: [TimeInterval] = []
    var auditStops = 0
    func scheduleEffectAuditRefresh(after delay: TimeInterval) { auditDelays.append(delay) }
    func stopEffectAuditRefreshTimer() { auditStops += 1 }
''']
for anchor in ['    func prepareForEffectsPresentation()', '    func setEffectScreenActive(_ isActive: Bool)', '    private func resumeDeferredOptionalQualityWork()']:
    parts.append(block(source, anchor).replace("private func", "func", 1))
parts.append('}')
Path(sys.argv[1]).write_text('\n'.join(parts))

# Also ensure the rendered page subscribes to the narrow observer, not telemetry.
page = view[view.index('private struct EffectsTabContent: View'):view.index('// MARK: - Navigation Views')]
assert '@ObservedObject var player' not in page
assert 'CoalescedViewUpdates(events: player.effectsPresentationEvents)' in page
