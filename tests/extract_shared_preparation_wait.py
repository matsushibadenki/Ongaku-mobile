from pathlib import Path
import sys
s=(Path(__file__).resolve().parent.parent/'audio/HiResPlaybackEngine.swift').read_text()
def block(a):
 start=s.index(a);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
method=block('    private func awaitPreloadedPlaybackData(').replace('private func','func',1)
helper=block('nonisolated private final class SharedPreparationWait:').replace('private final class','final class',1)
text='''import Foundation
@MainActor final class Fixture {
 struct Key:Hashable { var spatialProcessingApplied=false }
 struct Prepared { var spatialProcessingApplied=false;var id=1 }
 typealias PreloadedPlaybackKey = Key
 typealias PreparedPlaybackData = Prepared
 var preloadedPlaybackCache:[Key:Prepared]=[:]
 var preloadTasks:[Key:Task<Void,Never>]=[:]
'''+method+'\n}\n'+helper
# A cancelled cache waiter must not start a replacement worker at its call site.
assert s.count('let preloadedPrepared = await awaitPreloadedPlaybackData(for: preloadKey)\n        try Task.checkCancellation()')==3
Path(sys.argv[1]).write_text(text)
