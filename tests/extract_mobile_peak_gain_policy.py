"""Extract the shipping iOS gain calculation to prevent a test-only copy drifting."""
import re, sys
from pathlib import Path
s=Path('audio/HiResPlaybackEngine.swift').read_text()
keys=['floatPipelineTargetRMSDBFS','loudnessNormalizationTargetLUFS','floatPipelinePeakCeilingDBFS','finalOutputCeilingDBFS','intersamplePeakReserveDB','maxInputBoostDB','maxInputCutDB']
constants=[]
for key in keys:
 m=re.search(r'nonisolated private static let '+key+r': Float = ([^\n]+)',s)
 if not m: raise RuntimeError('missing '+key)
 constants.append('static let '+key+': Float = '+m.group(1))
start=s.index('        let rmsBasedTrim = Self.floatPipelineTargetRMSDBFS - sourceRMS',s.index('private func applyGainStaging'))
end=s.index('        // Both normal and high-quality players',start)
body=s[start:end].replace('outputLimiter == nil','!hasLimiter')
Path(sys.argv[1]).write_text('import Foundation\nenum ExtractedMobileGainPolicy {\n'+'\n'.join(constants)+'\n static func plan(sourceRMS: Float, sourceLoudness: Float, sourcePeak: Float, effectBoost: Float, hasLimiter: Bool) -> (Float, Float) {\n'+body+'return (inputTrimDB, outputTrimDB)\n}\n}\n')
