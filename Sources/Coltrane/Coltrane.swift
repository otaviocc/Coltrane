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

// swiftlint:disable identifier_name

/// The runtime: a fixed pool of virtual processors and the shared task graph
/// they cooperate on.
///
/// Programs describe concurrency by spawning jobs and joining their handles;
/// the runtime maps that work onto real threads using work-helping. Use the
/// shared instance via `Coltrane.shared`. `@unchecked Sendable` because all
/// shared state is guarded by `stateLock` or by a `JobList`'s own lock.
package final class Coltrane: @unchecked Sendable {

    // MARK: - Nested types

    /// Where a joining processor looks for pending work to help with.
    ///
    /// Helped work runs inline on the joining thread's call stack, so a strategy
    /// that can reach work outside the joined job's subtree
    /// (`anywhere`/`currentSubtree`) can deepen that stack beyond the program's
    /// own recursion on deep fork/join — risking overflow. `joinedSubtree`
    /// bounds the extra depth to the joined subtree and is the safe default.
    package enum HelpingStrategy {

        /// Help with any pending job anywhere in the graph. Best for flat,
        /// data-parallel fan-out; may grow the joining thread's stack on deep
        /// recursive workloads.
        case anywhere
        /// Help only within the subtree of the job currently running on this
        /// processor; may grow the joining thread's stack on deep recursion.
        case currentSubtree
        /// Help only within the subtree of the job being joined. The default;
        /// bounds extra stack growth to that subtree's depth.
        case joinedSubtree
    }

    // MARK: - Properties

    /// The shared runtime instance — the singleton used throughout the package.
    package static let shared = Coltrane()

    /// How long an idle processor parks before re-checking for work, in seconds.
    static let idlePollInterval: TimeInterval = 0.001

    /// The roots of the task graph: jobs spawned outside any running job.
    let rootList = JobList()
    /// Guards the virtual-processor set, thread map, counters, and run flag.
    let stateLock = NSLock()

    private var _helpingStrategy: HelpingStrategy = .joinedSubtree
    private var vpList: [VirtualProcessor] = []
    private var threadMap: [ObjectIdentifier: VirtualProcessor] = [:]
    private var nextJobId: UInt64 = 0
    private var _isRunning = false

    /// Whether a fully-joined job is spliced out of the graph. Tests may disable
    /// this to inspect graph structure after joins.
    var removeJobsEnabled = true

    /// Where joining processors look for work to help with. Defaults to
    /// `.joinedSubtree`.
    package var helpingStrategy: HelpingStrategy {
        get { stateLock.lock()
            defer { stateLock.unlock() }
            return _helpingStrategy
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _helpingStrategy = newValue
        }
    }

    /// Whether the runtime is running — between `initialize()` and `terminate()`.
    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    // MARK: - Life cycle

    private init() {}

    // MARK: - Public

    /// Starts the runtime with `maxVPs` virtual processors.
    ///
    /// The calling thread becomes VP 0; the rest are started as worker threads.
    /// Defaults to one processor per active core. Call `terminate()` when done.
    package func initialize(maxVPs: Int = ProcessInfo.processInfo.activeProcessorCount) {
        let count = max(1, maxVPs)

        stateLock.lock()
        nextJobId = 0
        _isRunning = true
        let main = VirtualProcessor(id: 0, isMain: true, runtime: self)
        vpList = [main]
        threadMap = [ObjectIdentifier(Thread.current): main]
        var workers: [VirtualProcessor] = []
        for slot in 1..<count {
            let worker = VirtualProcessor(id: slot, isMain: false, runtime: self)
            vpList.append(worker)
            workers.append(worker)
        }
        stateLock.unlock()

        for worker in workers {
            worker.startThread()
        }
    }

    /// Stops the runtime, joins all worker threads, and tears down the graph.
    ///
    /// Returns the number of jobs that were never joined — `0` for a
    /// well-behaved program — which callers may assert on.
    @discardableResult
    package func terminate() -> Int {
        stateLock.lock()
        _isRunning = false
        let workers = vpList.filter { !$0.isMain }
        stateLock.unlock()

        for worker in workers {
            worker.wakeIdle()
        }
        for worker in workers {
            worker.waitUntilFinished()
        }

        let leaked = destroyJobs(rootList)

        stateLock.lock()
        vpList = []
        threadMap = [:]
        stateLock.unlock()
        return leaked
    }

    /// Spawns `body` as a new job and returns a handle to its eventual result.
    ///
    /// The job is attached to the graph as a child of the job currently running
    /// on the calling processor (or as a root) and claimed by whichever
    /// processor reaches it first. The work runs only once the handle is joined
    /// or another processor picks it up; it does not start eagerly here.
    @discardableResult
    package func spawn<T: Sendable>(
        options: JobOptions = .init(),
        _ body: @escaping () -> T
    ) -> JobHandle<T> {
        if case let .specific(id) = options.affinity {
            precondition(
                findVP(id: id) != nil,
                "Coltrane: spawn requested .specific(\(id)) affinity, but no virtual processor has that id"
            )
        }
        let job = Job<T>(id: nextJobIdentifier(), options: options, body: body)
        job.status = .unassigned
        storeJob(job, currentVP: currentVP())
        return JobHandle(job: job)
    }

    /// Records that `thread` is running as `vp`, so `currentVP()` can map back.
    func register(thread: Thread, as vp: VirtualProcessor) {
        stateLock.lock()
        threadMap[ObjectIdentifier(thread)] = vp
        stateLock.unlock()
    }

    /// The virtual processor running on the calling thread, or `nil` if the
    /// thread is not one of the runtime's processors.
    func currentVP() -> VirtualProcessor? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return threadMap[ObjectIdentifier(Thread.current)]
    }

    /// The virtual processor with the given logical id, used to resolve
    /// `.specific` affinity.
    func findVP(id: Int) -> VirtualProcessor? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return vpList.first { $0.id == id }
    }

    /// Returns the next process-unique job identifier.
    func nextJobIdentifier() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextJobId
        nextJobId += 1
        return id
    }

    /// Attaches `job` to the graph: as a child of the job on top of `vp`'s
    /// stack if there is one, otherwise as a root.
    func storeJob(_ job: AnyJob, currentVP vp: VirtualProcessor?) {
        if let vp, let parent = vp.jobStack.last {
            parent.children.append(job)
        } else {
            rootList.append(job)
        }
    }

    // MARK: - Private

    @discardableResult
    private func destroyJobs(_ list: JobList) -> Int {
        var leaked = 0
        for entry in list.reversedSnapshot {
            leaked += destroyJobs(entry.children)
            entry.completion.lock()
            let status = entry.status
            entry.completion.unlock()
            if status != .joined {
                leaked += 1
                FileHandle.standardError.write(
                    Data("Coltrane: destroyJobs => job \(entry.id) status \(status) (expected .joined)\n".utf8)
                )
            }
        }
        list.removeAll()
        return leaked
    }
}
