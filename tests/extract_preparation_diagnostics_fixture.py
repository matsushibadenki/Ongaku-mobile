"""Extract the shipping preflight and allocation checks; virtualize only memory availability."""
from pathlib import Path
import sys
source = Path('audio/HiResPlaybackEngine.swift').read_text().replace('effectProtectionGain', 'declickMixer.outputVolume').replace('transportOutputGain', 'engine.mainMixerNode.outputVolume')
vm = Path('audio/AudioPlayerViewModel.swift').read_text()
def block(anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
# Guard the production callers that previously discarded failure details.
assert 'canPrepareOffline' not in source + vm
assert 'load failed with' not in vm
assert 'path=streaming requestedMode=' in vm
assert 'outcome=\\(outcome)' in source
assert 'try Self.validateOfflinePreparation(url: input' in block('    nonisolated static func prepareDiskCache(')
for name in ['offlineOpen', 'offlineBudget', 'offlineConversion', 'offlineSpatial', 'offlineValidation']:
    assert f'.{name}' in block('    nonisolated private static func preparePlaybackData(')
assert '.qualityHandoff' in block('    func seamlessUpgrade(')
assert '.streamingSession' in block('    func load(') and '.streamingGraph' in block('    func load(')
text = '''import AVFoundation
import Foundation
// Transport/DSP models are not involved in metadata-only preflight.
enum UpsamplingMode { case avAudioConverter, precisionSincLinearEco
    var isPrecisionSinc: Bool { self != .avAudioConverter }
}
enum L10n { static func tr(_ key: String, _ values: CVarArg...) -> String { key } }
nonisolated(unsafe) var simulatedAvailableMemory: UInt64 = 0
nonisolated func availableAudioProcessMemoryBytes() -> UInt64 { simulatedAvailableMemory }
'''
text += block('private enum HiResEngineError:').replace('private enum', 'enum', 1).replace('    @MainActor\n', '')
original = source
source = Path('audio/RemoteAudioCache.swift').read_text()
text += '\n' + block('nonisolated enum RemoteAudioCacheError:') + '\n'
source = original
text += '\nenum ShippingPreparationPreflight {\n'
for name in ['maxOfflinePlaybackBufferBytes', 'minimumProcessMemoryReserveBytes', 'maximumProcessMemoryReserveBytes']:
    lines = [line for line in source.splitlines() if f'let {name}:' in line]
    assert len(lines) == 1
    text += lines[0] + '\n'
text += 'static func resolvedProcessingSampleRate(for rate: Double) -> Double { AudioProcessingPolicy.processingSampleRate(for: rate) }\n'
preflight = block('    nonisolated static func validateOfflinePreparation(')
if '--capacity-for-all-fixture' in sys.argv:
    preflight = preflight.replace('try AVAudioFile(forReading: url)', 'try legacyOpen(url)')
    text += '''static func legacyOpen(_ url: URL) throws -> AVAudioFile {
        do { return try AVAudioFile(forReading: url) }
        catch { throw HiResEngineError.offlineBufferTooLarge }
    }
'''
text += preflight + '\n'
a = source.index('    nonisolated private static func checkedAudioFrameCount(')
b = source.index('    nonisolated private static func validateOfflineBufferFootprint(', a)
text += source[a:b].replace('private static', 'static')
for name in ['validateOfflineBufferFootprint', 'validateOfflineProcessingFootprint', 'estimatedBufferBytes']:
    text += block(f'    nonisolated private static func {name}(').replace('private static', 'static', 1) + '\n'
text += '}\n'
Path(sys.argv[1]).write_text(text)
