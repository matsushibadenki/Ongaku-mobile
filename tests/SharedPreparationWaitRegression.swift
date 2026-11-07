import Foundation
@main struct SharedPreparationWaitRegression {
 @MainActor static func main() async {
  let key=Fixture.Key()
  let f=Fixture()
  var continuation:CheckedContinuation<Void,Never>?
  let producer=Task { @MainActor in
   await withCheckedContinuation {continuation=$0}
   f.preloadedPlaybackCache[key] = .init()
  }
  f.preloadTasks[key]=producer
  while continuation == nil {await Task.yield()}
  let caller=Task {await f.awaitPreloadedPlaybackData(for:key)}
  await Task.yield();await Task.yield()
  let request=Date();caller.cancel()
  let result=await caller.value
  precondition(result==nil && !producer.isCancelled && f.preloadedPlaybackCache.isEmpty)
  print("PASS: cancelled shared waiter returns without producer completion; elapsedMs=\(Date().timeIntervalSince(request)*1000)")
  continuation!.resume();await producer.value
  let other=await f.awaitPreloadedPlaybackData(for:key)
  precondition(other?.id==1 && f.preloadedPlaybackCache.isEmpty)
  print("PASS: shared producer remains usable by another caller")
  let cached=Fixture();cached.preloadedPlaybackCache[key] = .init()
  let cancelled=Task {await cached.awaitPreloadedPlaybackData(for:key)};cancelled.cancel()
  let ignored=await cancelled.value
  precondition(ignored==nil && cached.preloadedPlaybackCache[key]?.id==1)
  print("PASS: pre-cancelled caller does not consume prepared cache")
  for _ in 0..<200 {
   let waiter=SharedPreparationWait()
   async let cancelled:Void = Task.detached {waiter.resolve(false)}.value
   let value=await withCheckedContinuation {c in
    if waiter.install(c) {waiter.resolve(true)}
   }
   _ = value;await cancelled
  }
  print("PASS: 200 installation/completion/cancellation races resume once")
 }
}
