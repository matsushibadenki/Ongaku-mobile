"""Shipping HRTF adjunct for the combined sinc / meter / effect waveform host."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
source = (root / 'audio/HiResPlaybackEngine.swift').read_text()
models = (root / 'audio/AppLibraryModels.swift').read_text()

def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    opening = (text.index('    ) throws {', start) + len('    ) throws ')
               if 'applyHeadphoneVirtualizationIfNeeded(' in anchor else text.index('{', start))
    end = opening + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

parts = ['import AVFoundation\nimport Foundation',
         block(models, 'nonisolated enum HeadphoneHRTFPreset:'),
         block(models, 'nonisolated struct HeadphoneSpatialSettings:'),
         block(source, 'private struct BiquadFilter {'),
         'enum ShippingHRTF { static let shouldApplyHeadphoneVirtualization = true']
for anchor in ['    nonisolated static func applyHeadphoneVirtualizationIfNeeded(',
               '    private struct HRTFImpulseResponseTap {',
               '    nonisolated private static func hrtfImpulseResponseTaps(',
               '    private struct HeadphoneHRTFProfile {',
               '    nonisolated private static func headphoneHRTFProfile(',
               '    nonisolated private static func clonePlaybackBuffer(']:
    parts.append(block(source, anchor).replace('private ', ''))
parts.append('}')
Path(sys.argv[1]).write_text('\n\n'.join(parts))
