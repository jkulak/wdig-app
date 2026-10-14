import Foundation
import Synchronization

/// What a write to the store touched: the local days whose points or segments changed, so a
/// screen showing one day can tell whether it has to load again.
struct StoreChange: Sendable, Equatable {
    var days: Set<String>

    func touches(_ day: String) -> Bool {
        days.contains(day)
    }
}

/// The store's writes, broadcast to whoever subscribes. Each subscriber gets a stream of its
/// own that ends with its task, and the store publishes without leaving its actor, so a write
/// never waits on a reader.
final class StoreChangeSignal: Sendable {
    private struct Subscribers {
        var continuations: [Int: AsyncStream<StoreChange>.Continuation] = [:]
        var nextId = 0
    }

    private let subscribers = Mutex(Subscribers())

    func subscribe() -> AsyncStream<StoreChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: StoreChange.self, bufferingPolicy: .unbounded)
        let id = subscribers.withLock { subscribers in
            let id = subscribers.nextId
            subscribers.nextId += 1
            subscribers.continuations[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { $0.continuations[id] = nil }
        }
        return stream
    }

    func publish(_ change: StoreChange) {
        guard !change.days.isEmpty else { return }
        for continuation in subscribers.withLock({ Array($0.continuations.values) }) {
            continuation.yield(change)
        }
    }
}
