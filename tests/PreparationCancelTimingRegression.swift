import Foundation
@main struct PreparationCancelTimingRegression {
 static func main() {
  let clock=PreparationCancellationTiming()
  precondition(clock.latencyMilliseconds(now:100)==nil)
  clock.markRequested(now:1_000_000_000)
  clock.markRequested(now:2_000_000_000)
  precondition(clock.latencyMilliseconds(now:1_125_000_000)==125)
  precondition(clock.latencyMilliseconds(now:999_999_999)==nil)
  print("PASS: unknown request, first request retained, monotonic nanoseconds and invalid interval")
  let race=PreparationCancellationTiming()
  DispatchQueue.concurrentPerform(iterations:200) { index in race.markRequested(now:UInt64(index+1)) }
  let value=race.latencyMilliseconds(now:1_000)!
  precondition(value >= 0.0008 && value <= 0.000999)
  print("PASS: concurrent request recording stays consistent")
 }
}
