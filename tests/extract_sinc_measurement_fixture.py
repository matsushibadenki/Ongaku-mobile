"""Compile shipping sinc methods verbatim without the iOS transport/UI host.

Fail closed on missing/duplicate anchors. No DSP replacement or copied kernel
implementation is maintained here. macOS memory availability is zero in shipping
code too; transport, HRTF, dither and adaptive gain are outside this fixture.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
engine = (root / 'audio/HiResPlaybackEngine.swift').read_text().replace('effectProtectionGain', 'declickMixer.outputVolume').replace('transportOutputGain', 'engine.mainMixerNode.outputVolume')
models = (root / 'audio/AppLibraryModels.swift').read_text()

def block(source, anchor):
    if source.count(anchor) != 1:
        raise RuntimeError(f'Expected exactly one anchor: {anchor}')
    start = source.index(anchor)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

methods = [
    'makeChunkedPrecisionSincPlaybackBuffer', 'cooperativelyThrottleOfflineProcessing',
    'normalizePrecisionSincSourceChunk', 'renderSincChunk', 'convertBuffer',
    'validateOfflineBufferFootprint', 'cachedPolyphaseSincKernels',
    'minimumPhaseKernel', 'sincCoefficientFloat', 'besselI0', 'kaiserWindow',
    'resampleBufferWithWindowedSinc', 'renderSincChannel',
]
output = ['import AVFoundation\nimport Accelerate\nimport Foundation\n']
for name in ['PrecisionSincPhaseMode', 'PrecisionSincQualityMode']:
    output.append(block(models, f'nonisolated enum {name}:'))
output.append('enum HiResEngineError: Error { case upconvertFailed, upconvertBufferFailed, sourceBufferFailed, offlineBufferTooLarge }')
output.append(block(engine, 'nonisolated private func availableAudioProcessMemoryBytes()'))
output.append('enum ShippingSincMeasurement {')
output.append(block(engine, 'private static func playbackSlice(').replace('private static func', 'static func', 1))
for name in ['maxOfflinePlaybackBufferBytes', 'proactiveMemoryPressureThresholdBytes', 'sincKernelCacheLock']:
    lines = [line for line in engine.splitlines() if re.search(r'\blet ' + name + r'\b', line)]
    if len(lines) != 1: raise RuntimeError(name)
    output.append(lines[0])
output.append('nonisolated(unsafe) private static var sincKernelCache: [SincKernelCacheKey: [Float]] = [:]')
for name in methods:
    text = block(engine, f'nonisolated private static func {name}(')
    if name in ['makeChunkedPrecisionSincPlaybackBuffer', 'resampleBufferWithWindowedSinc']:
        text = text.replace('nonisolated private static', 'nonisolated static', 1)
    output.append(text)
# Both shipping frame-count overloads, with their validation intact.
start = engine.index('    nonisolated private static func checkedAudioFrameCount(')
end = engine.index('    nonisolated private static func validateOfflineBufferFootprint(', start)
output.append(engine[start:end])
output.append("""
// Measurement adapter only: invoke the shipping absolute-position renderer on
// the entire source to isolate chunk-window offsets from phase accumulation.
static func absolutePositionReference(_ source: AVAudioPCMBuffer, target: AVAudioFormat,
    phase: PrecisionSincPhaseMode, quality: PrecisionSincQualityMode) throws -> AVAudioPCMBuffer {
    let ratio = target.sampleRate / source.format.sampleRate
    let count = try checkedAudioFrameCount(ceil(Double(source.frameLength) * ratio), format: target, failure: .upconvertBufferFailed)
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: count)!
    let profile = quality.sincKernelProfile
    let radius = profile.radius * (phase == .minimumPhase ? 3 : 1)
    let size = profile.radius * (phase == .minimumPhase ? 4 : 2) + 1
    let kernels = cachedPolyphaseSincKernels(cutoff: Float(min(1, ratio) * Double(phase.cutoffScale)),
        kernelRadius: radius, kernelSize: size, numPhases: profile.numPhases, phaseMode: phase, qualityMode: quality)
    try kernels.withUnsafeBufferPointer { values in
        for channel in 0..<Int(target.channelCount) {
            try renderSincChunk(source: source.floatChannelData![channel], sourceFrameCount: Int(source.frameLength),
                sourceFrameOffset: 0, output: output.floatChannelData![channel], outputStartFrame: 0,
                outputFrameCount: Int(count), kernels: values.baseAddress!, ratio: ratio,
                kernelRadius: radius, kernelSize: size, numPhases: profile.numPhases)
        }
    }
    output.frameLength = count
    return output
}
""")
output.append('}')
for anchor in ['nonisolated private struct SincKernelCacheKey:', 'nonisolated private struct SincKernelProfile:',
               'private extension PrecisionSincPhaseMode', 'private extension PrecisionSincQualityMode']:
    output.append(block(engine, anchor))
Path(sys.argv[1]).write_text('\n\n'.join(output) + '\n')
