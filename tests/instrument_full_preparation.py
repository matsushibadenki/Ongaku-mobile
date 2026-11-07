"""Add timing/cancellation gates to an isolated module copy, never the product."""
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
# Function-scope spans preserve the original operations and nested stage owner.
for name,stage in [('preparePlaybackData','prepare'),('makeChunkedPrecisionSincPlaybackBuffer','conversion'),('cachedPolyphaseSincKernels','kernel'),('minimumPhaseKernel','fft'),('normalizePrecisionSincSourceChunk','normalize'),('clonePlaybackBuffer','copy'),('analyzeSignalLevels','analysis'),('analyzeAutomaticDSP','auto_analysis'),('isFiniteAudioBuffer','validation'),('readPCMBuffer','cache_read'),('storePreparedPlaybackDataOnDisk','persist')]:
 needle='static func '+name+'(';assert s.count(needle)==1,(name,s.count(needle))
 a=s.index(needle);b=s.index('{',a)+1
 s=s[:b]+f'\n        let auditStage = FullPreparationProbe.begin("{stage}")\n        defer {{ FullPreparationProbe.end("{stage}", auditStage) }}\n'+s[b:]
a=s.index('static func applyHeadphoneVirtualizationIfNeeded(');b=s.index(') throws {',a)+len(') throws {')
s=s[:b]+'\n        let auditSpatial = FullPreparationProbe.begin("spatial")\n        defer { FullPreparationProbe.end("spatial", auditSpatial) }\n'+s[b:]
s=s.replace('AVAudioPCMBuffer(', 'FullPreparationProbe.buffer(')
# A zero-copy playback slice uses a different initializer and allocates no PCM.
a=s.index('private static func playbackSlice(');b=s.index('nonisolated private static func',a)
s=s[:a]+s[a:b].replace('FullPreparationProbe.buffer(', 'AVAudioPCMBuffer(')+s[b:]
s=s.replace('vDSP_DFT_Execute(', 'FullPreparationProbe.fft(')
s=s.replace('try audioFile.read(into: sourceChunk, frameCount: sourceChunkCapacity)', 'try FullPreparationProbe.read(audioFile, into: sourceChunk, frameCount: sourceChunkCapacity)')
s=s.replace('try file.read(into: buffer, frameCount: frameCount)', 'try FullPreparationProbe.read(file, into: buffer, frameCount: frameCount)')
s=s.replace('Thread.sleep(forTimeInterval: interval)', 'FullPreparationProbe.sleep(interval)')
s+='''
extension HiResPlaybackEngine {
 nonisolated static func auditFullPrepare(_ url: URL, mode: UpsamplingMode = .precisionSincMinimumPhaseEco) throws -> Int {
  let prepared = try preparePlaybackData(url: url, headphoneSpatialSettings: .default,
       upsamplingMode: mode, storeSynchronously: true)
  return Int(prepared.playbackBuffer.frameLength)
 }
 nonisolated static func auditOptionalSpatial(_ buffer: AVAudioPCMBuffer) throws -> Int {
  let copy = try clonePlaybackBuffer(from: buffer)
  for channel in 0..<Int(buffer.format.channelCount) {
   guard UnsafeBufferPointer(start: copy.floatChannelData![channel], count: Int(copy.frameLength)).elementsEqual(
    UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))) else { throw HiResEngineError.upconvertFailed }
  }
  try applyHeadphoneVirtualizationIfNeeded(to: copy, settings: .default, routeSupportsSpatial: true)
  try Task.checkCancellation()
  guard isFiniteAudioBuffer(copy) else { throw HiResEngineError.upconvertFailed }
  return Int(copy.frameLength)
 }
 nonisolated static func auditIndependentStore(_ url: URL) throws -> (Task<Void, Never>?, URL, URL) {
  let prepared = try preparePlaybackData(url: url, headphoneSpatialSettings: .default,
       upsamplingMode: .precisionSincMinimumPhaseEco, skipDSPAnalysis: true)
  let signature = fileSignatureForCache(url: url)
  let paths = preparedAudioDiskCachePaths(url: url, sourceFileSize: signature.fileSize,
      sourceModificationTime: signature.modificationTime, targetSampleRate: prepared.targetFormat.sampleRate,
      upsamplingMode: prepared.upsamplingMode, spatialSettings: .default,
      spatialProcessingApplied: prepared.spatialProcessingApplied)!
  schedulePreparedPlaybackDataDiskStore(prepared, sourceFileSize: signature.fileSize,
      sourceModificationTime: signature.modificationTime, spatialSettings: .default,
      spatialProcessingApplied: prepared.spatialProcessingApplied)
  preparedAudioDiskCacheTaskLock.lock()
  let task = preparedAudioDiskCacheWriteTask
  preparedAudioDiskCacheTaskLock.unlock()
  return (task, paths.metadata, paths.baseAudio)
 }
 nonisolated static func auditResetPreparation() { clearAnalysisCache(); clearSincKernelCache() }
 nonisolated static func auditAnalysisCount() -> Int {
  analysisCacheLock.lock(); defer { analysisCacheLock.unlock() }; return analysisCache.count
 }
}
'''
p.write_text(s)
