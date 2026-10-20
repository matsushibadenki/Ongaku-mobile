"""Extract production foreground reconciliation and fresh-progress wait methods.
Only OS/player collaborators are virtualized; assertions exercise shipping control flow.
"""
from pathlib import Path
import sys
vm = Path('audio/AudioPlayerViewModel.swift').read_text()
engine = Path('audio/HiResPlaybackEngine.swift').read_text()
def block(source, anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('@objc ', '').replace('private ', '')
parts = [Path('tests/ForegroundRecoveryFixture.swift').read_text()]
parts += ['extension ForegroundHost {']
for anchor in ['@objc private func handleAppDidBecomeActive()',
               'private func reconcileLocalPlaybackAfterForeground()',
               'private func resumePendingInterruptionIfNeeded()',
               'private var actualPlaybackState:',
               'private func scheduleUnexpectedLocalPlaybackRecovery(']:
    method = block(vm, anchor)
    if '--refresh-first' in sys.argv:
        method = method.replace('reconcileLocalPlaybackAfterForeground()',
            'refreshPlaybackState(); reconcileLocalPlaybackAfterForeground()', 1) if anchor.startswith('@objc') else method
    parts.append(method)
parts += [block(vm, 'private func clearInterruptionResumeState()'),
          block(vm, 'private func resumePlaybackAfterInterruption(').replace('func resumePlaybackAfterInterruption(', 'func runInterruptionResume(', 1)]
parts += ['}', 'extension ProgressHost {', block(engine, 'func waitForPlaybackProgress()'), '}']
output = '\n'.join(parts)
if '--discard-eof' in sys.argv:
    output = output.replace('self.handleLocalPlaybackEnded()', '/* fault injection: discard deferred EOF */')
Path(sys.argv[1]).write_text(output)
