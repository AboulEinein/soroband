import Dispatch

/// Work that blocks its thread (a database read, a file write) runs on Dispatch's threads, never on
/// Swift concurrency's: those are one per CPU, and once every one of them waits, no task in the
/// process runs, the main actor's included.
enum BlockingWork {
    private static let queue = DispatchQueue.global(qos: .userInitiated)

    /// Runs `work` on a Dispatch thread and returns its result.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Runs `work` on a Dispatch thread, then `then` on the main thread with its result.
    static func run<T: Sendable>(
        _ work: @escaping @Sendable () -> T, then: @escaping @MainActor @Sendable (T) -> Void
    ) {
        queue.async {
            let result = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
        }
    }
}
