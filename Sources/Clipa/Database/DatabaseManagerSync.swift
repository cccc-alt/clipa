import Dispatch
import Foundation

/// Dedicated serial executor for the database actor.
///
/// Swift's cooperative pool has one thread per core and never grows, so any job
/// that has to wait for it can be starved by unrelated blocking work. Handing
/// `DatabaseManager` its own queue means SQLite always has a thread to run on:
/// a saturated pool slows everything else down, but it can no longer make the
/// database itself un-schedulable.
///
/// The queue is the actor's executor *and* the only thread that touches the
/// SQLite connection, so actor isolation still serializes every statement.
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

/// Reports the one call pattern the blocking bridges cannot survive.
///
/// `@available(*, noasync)` already rejects the direct form (`TaskBlocking.run`
/// written inside an async function), but it cannot see an indirection: a plain
/// `func f()` that calls the bridge is legal on its own, and the deadlock only
/// appears when `f()` happens to run inside a `Task`. `withUnsafeCurrentTask`
/// answers that at run time — a non-main thread that is executing a Swift task
/// is a cooperative-pool (or actor-executor) thread, and blocking it while the
/// inner task needs one is exactly the hang described above.
///
/// It logs instead of trapping: a freeze should become a diagnosable freeze,
/// not a crash in a shipped build.
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

/// Bridges an actor-isolated call to a synchronous caller. Every call still
/// hops through the actor, so SQLite is serialized by actor isolation instead
/// of a hand-rolled queue.
///
/// **Never call this from a cooperative thread** (i.e. from inside a `Task`).
/// The pool has exactly one thread per core and does not grow when a thread
/// blocks, while the inner `Task` needs a pool thread to run: as many
/// simultaneous waits as the machine has cores deadlock the process. Measured
/// on an 8-core machine: 6 concurrent waits complete, 8 hang. Callers that
/// already run inside a task must `await` the actor directly — that is what
/// `LocalSearchEngine.searchAsync`, `LocalSearchLearner.predictAsync`,
/// `ClipStore.imageDataAsync` and `ClipStore.assetAvailabilityAsync` are for.
///
/// `DatabaseManager` runs on its own `DatabaseExecutor`, so the *database* side
/// of a wait can always make progress; it is still the caller's thread that is
/// held, which is why the rule above stays a rule.
enum TaskBlocking {
    /// Blocks the calling thread until `operation` finishes. The result is
    /// guaranteed to be written before `wait()` returns.
    ///
    /// `noasync` makes the rule above a *compile-time* one: calling this from
    /// an async context is now an error, so the deadlock the comment describes
    /// can no longer be introduced by accident — the compiler points at the
    /// call site and names the async twin to use instead.
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
        // Safe: the task assigns before signalling.
        return result!
    }
}

/// Synchronous bridge for the database actor. See `TaskBlocking` for the
/// threading constraint.
enum DatabaseSync {
    /// See `TaskBlocking.run`: `noasync` turns the threading rule this whole
    /// file documents into something the compiler enforces.
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
