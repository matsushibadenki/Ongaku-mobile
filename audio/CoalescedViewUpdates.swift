import Combine
import Foundation

/// Observes only the signals a screen uses, and folds a synchronous batch of
/// Published writes into one update after the model has committed its values.
@MainActor
final class CoalescedViewUpdates: ObservableObject {
    private var subscription: AnyCancellable?

    init(events: [AnyPublisher<Void, Never>]) {
        subscription = Publishers.MergeMany(events)
            .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
    }
}

