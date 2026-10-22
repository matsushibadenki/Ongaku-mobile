"""Extract shipping prepared scheduling, deadline rejection and EOF acceptance.
Virtualize player callbacks/queue timing so failed replacements are deterministic.
"""
from pathlib import Path
import sys
source = Path('audio/HiResPlaybackEngine.swift').read_text().replace('effectProtectionGain', 'declickMixer.outputVolume').replace('transportOutputGain', 'engine.mainMixerNode.outputVolume')
def block(anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')
commit_start = source.index('        let nextGeneration = playbackGeneration &+ 1')
commit_end = source.index('        playbackGeneration = nextGeneration', commit_start)
commit = source[commit_start:commit_end] + '        playbackGeneration = nextGeneration\n'
fixture = '''import Foundation
import AVFoundation
enum HiResEngineError: Error { case upconvertBufferFailed }
struct PlaybackDebugLogger { static func event(_ text: String) {} }
struct TestSession {
    static func sharedInstance() -> Self { Self() }
    let ioBufferDuration = 0.005
}
struct Monitor { func endMonitoring() {} }
final class CallbackQueue {
    var pending: [() -> Void] = []
    func async(execute: @escaping () -> Void) { pending.append(execute) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}
enum DispatchQueue { static let main = CallbackQueue() }
final class AVAudioPlayerNode {
    enum CompletionType { case dataPlayedBack }
    var volume: Float = 1
    var completion: ((CompletionType) -> Void)?
    func stop() { let old = completion; completion = nil; old?(.dataPlayedBack) }
    func reset() {}
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at: AVAudioTime?, options: [Int],
                        completionCallbackType: CompletionType,
                        completionHandler: @escaping (CompletionType) -> Void) {
        completion = completionHandler
    }
    func complete() { completion?(.dataPlayedBack) }
}
final class PreparedEOFHost {
    var handoffScheduleToken: UInt64 = 0
    var preparedPlaybackScheduleTokens: [ObjectIdentifier: UInt64] = [:]
    var playbackGeneration: UInt64 = 0
    var playbackEndedGeneration: UInt64?
    var transportStopPending = false
    var pendingTransportPause: Double?
    var transportSeekPending = false
    var transportReachedEnd = false
    var transportFadeInPending = false
    var playbackStartedAt: Date?
    var playbackOffset = 0.0
    var lastKnownPlaybackTime = 0.0
    let duration = 10.0
    let renderHealthMonitor = Monitor()
    var onPlaybackEnded: (() -> Void)?
    static func playbackSlice(from buffer: AVAudioPCMBuffer, startingFrame: AVAudioFramePosition,
                              frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? { buffer }
    func attempt(_ playbackBuffer: AVAudioPCMBuffer, on newNode: AVAudioPlayerNode,
                 timely: Bool, invalidTail: Bool = false) throws {
        let plan = (startFrame: AVAudioFramePosition(invalidTail ? playbackBuffer.frameLength : 0), unused: 0)
        let startHost: UInt64 = timely ? mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 10) : 0
'''
fixture += commit.replace('AVAudioSession.', 'TestSession.') + '\n}\n'
for anchor in ['private func schedulePreparedBuffer(', 'private func handlePlaybackEnd(']:
    method = block(anchor)
    if '--global-token' in sys.argv:
        method = method.replace('self.preparedPlaybackScheduleTokens[nodeID] == scheduleToken',
                                'self.handoffScheduleToken == scheduleToken')
    fixture += method + '\n'
Path(sys.argv[1]).write_text(fixture + '}\n')
