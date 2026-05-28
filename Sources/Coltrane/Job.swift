// MIT License
//
// Copyright (c) 2026 Otávio C.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

/// The lifecycle state of a job as it moves through the scheduler.
///
/// A job normally progresses `unassigned → assigned → executing → done →
/// joined`. A virtual processor may take an `unassigned` job straight to
/// `executing` when it claims and runs it inline during a join.
enum JobStatus {

    /// Created, but no virtual processor has claimed it yet.
    case unassigned
    /// Claimed by a virtual processor but not yet started.
    case assigned
    /// Currently running on a virtual processor's call stack.
    case executing
    /// Finished; its result is available but it has not been joined yet.
    case done
    /// Result consumed by a join; eligible for removal from the graph.
    case joined
}

/// A type-erased node in the task graph.
///
/// The graph is heterogeneous — jobs may produce different result types — so it
/// is traversed through this existential. The concrete, result-typed storage
/// lives in `Job`.
protocol AnyJob: AnyObject {

    // MARK: - Properties

    /// Process-unique identifier, assigned in spawn order.
    var id: UInt64 { get }
    /// The job's current lifecycle state. Guarded by `completion`.
    var status: JobStatus { get set }
    /// Which virtual processor, if any, this job must run on.
    var affinity: ProcessorAffinity { get set }
    /// The virtual processor that claimed the job, once one has.
    var owner: VirtualProcessor? { get set }
    /// Scheduling attributes such as the join count and detach state.
    var options: JobOptions { get set }
    /// Jobs spawned while this job was executing — its children in the graph.
    var children: JobList { get }
    /// The list this node currently lives in, used when it is removed.
    var parentList: JobList? { get set }
    /// Condition broadcast when the job reaches `.done`; also guards `status`.
    var completion: NSCondition { get }

    // MARK: - Public

    /// Runs the job's work on the calling thread and publishes its result.
    func run()
}

/// A unit of work in the runtime: a closure plus its task-graph bookkeeping.
///
/// `@unchecked Sendable` is deliberate — the type coordinates its own
/// synchronization. `status` and `result` are guarded by `completion`, and the
/// structural links are guarded by the enclosing `JobList`.
final class Job<T: Sendable>: AnyJob, @unchecked Sendable {

    // MARK: - Properties

    /// Process-unique identifier, assigned in spawn order.
    let id: UInt64
    /// Jobs spawned while this job was executing — its children in the graph.
    let children = JobList()
    /// Condition broadcast when the job reaches `.done`; also guards `status`
    /// and `result`.
    let completion = NSCondition()
    /// The work this job performs, run by `run()`.
    let body: () -> T

    /// The job's current lifecycle state. Guarded by `completion`.
    var status: JobStatus = .unassigned
    /// Which virtual processor, if any, this job must run on.
    var affinity: ProcessorAffinity = .any
    /// Scheduling attributes such as the join count and detach state.
    var options: JobOptions

    /// The virtual processor that claimed the job, once one has.
    weak var owner: VirtualProcessor?
    /// The list this node currently lives in, used when it is removed.
    weak var parentList: JobList?

    /// The produced result, set by `run()`; `nil` until the job is `.done`.
    private(set) var result: T?

    /// The job's result. Only valid once the job is `.done`; reads under
    /// `completion` and traps if called before the result has been produced.
    var storedResult: T {
        completion.lock()
        defer { completion.unlock() }
        guard let result else {
            preconditionFailure("Coltrane: result read before job \(id) reached .done")
        }
        return result
    }

    // MARK: - Life cycle

    /// Creates an unassigned job with the given identifier, options, and work.
    init(id: UInt64, options: JobOptions, body: @escaping () -> T) {
        self.id = id
        self.options = options
        affinity = options.affinity
        self.body = body
    }

    // MARK: - Public

    /// Executes `body` on the calling thread, stores the result, marks the job
    /// `.done`, and wakes anyone waiting on `completion`.
    func run() {
        let value = body()
        completion.lock()
        result = value
        status = .done
        completion.broadcast()
        completion.unlock()
    }
}
