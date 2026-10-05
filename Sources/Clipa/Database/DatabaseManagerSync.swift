import Dispatch
import Foundation

final class DatabaseExecutor: SerialExecutor {
    private let queue = DispatchQueue(
        label: "app.il.database-executor",
        qos: .userInitiated
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

enum CooperativeThreadWatchdog {
    private static let lock = NSLock()
    private static var hasWarned = false

    static func check() {
        guard !Thread.isMainThread else { return }
        var insideTask = false
        withUnsafeCurrentTask { insideTask = $0 != nil }
        guard insideTask else { return }
        lock.lock()
        let isFirst = !hasWarned
        hasWarned = true
        lock.unlock()
        guard isFirst else { return }
        NSLog(
            "Clipa: a blocking database bridge was called from a Swift "
                + "concurrency thread. The inner task needs a thread from the "
                + "same pool, so this can hang the process — await the actor "
                + "directly (the …Async twins) instead."
        )
    }
}

enum TaskBlocking {

    @available(
        *,
        noasync,
        message: """
        Blocking the cooperative pool deadlocks the process: the inner task \
        needs a pool thread while this call holds one. Await the actor directly \
        (ClipStore.imageDataAsync / assetAvailabilityAsync, \
        LocalSearchEngine.searchAsync) instead.
        """
    )
    static func run<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        CooperativeThreadWatchdog.check()
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = await operation()
            semaphore.signal()
        }
        semaphore.wait()

        return result!
    }
}

enum DatabaseSync {

    @available(
        *,
        noasync,
        message: """
        Blocking the cooperative pool deadlocks the process: the inner task \
        needs a pool thread while this call holds one. Await the actor directly \
        instead (the `…Async` twins on ClipStore).
        """
    )
    static func run<T>(
        _ database: DatabaseManager,
        _ operation: @escaping @Sendable (DatabaseManager) async throws -> T
    ) throws -> T {
        CooperativeThreadWatchdog.check()
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error> = .failure(
            DatabaseError.connectionFailed("database task did not start")
        )
        Task {
            do {
                outcome = .success(try await operation(database))
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }
}
