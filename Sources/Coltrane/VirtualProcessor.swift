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

#if canImport(Glibc)
    import Glibc
#endif

/// One worker in the pool: a thread (or, for VP 0, the calling thread) that
/// claims and runs jobs.
///
/// `@unchecked Sendable` because `jobStack` is only ever touched by this
/// processor's own thread and the rest of its state is self-synchronizing.
final class VirtualProcessor: @unchecked Sendable {

    // MARK: - Properties

    /// Logical id, unique within the runtime; VP 0 is the main thread.
    let id: Int
    /// Whether this is VP 0 (the calling thread), which has no spawned thread.
    let isMain: Bool
    /// The jobs currently executing on this processor's call stack, innermost
    /// last. Touched only by this processor's own thread.
    var jobStack: [AnyJob] = []

    private let idle = NSCondition()
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private unowned let runtime: Coltrane

    // MARK: - Life cycle

    /// Creates a processor with the given id, bound to `runtime`.
    init(id: Int, isMain: Bool, runtime: Coltrane) {
        self.id = id
        self.isMain = isMain
        self.runtime = runtime
    }

    // MARK: - Public

    /// Spawns the backing OS thread and starts its run loop. Must not be called
    /// on the main processor (VP 0).
    func startThread() {
        precondition(!isMain, "VP 0 (main) must not spawn a thread")
        let t = Thread { [weak self] in self?.runLoop() }
        t.stackSize = 8 << 20
        t.name = "Coltrane.VP\(id)"
        thread = t
        t.start()
    }

    /// The worker loop: claim and run pending jobs from the graph, parking
    /// briefly when there is none, until the runtime stops.
    func runLoop() {
        runtime.register(thread: Thread.current, as: self)
        bindToCore(id)

        while runtime.isRunning {
            if let job = runtime.searchJobs(.unassigned, in: runtime.rootList, claimingVP: self) {
                runtime.executeJob(job, on: self)
            } else {
                idleWait()
            }
        }
        finished.signal()
    }

    /// Wakes the processor if it is parked, so it re-checks for work or notices
    /// that the runtime has stopped.
    func wakeIdle() {
        idle.lock()
        idle.broadcast()
        idle.unlock()
    }

    /// Blocks until this processor's run loop has exited. Used during teardown.
    func waitUntilFinished() {
        finished.wait()
    }

    // MARK: - Private

    private func idleWait() {
        idle.lock()
        idle.wait(until: Date().addingTimeInterval(Coltrane.idlePollInterval))
        idle.unlock()
    }

    private func bindToCore(_ logicalId: Int) {
        #if os(Linux)
            var set = cpu_set_t()
            let cpu = logicalId % max(1, ProcessInfo.processInfo.activeProcessorCount)
            __CPU_SET(cpu, &set)
            _ = pthread_setaffinity_np(pthread_self(), MemoryLayout<cpu_set_t>.size, &set)
        #else
            _ = logicalId
        #endif
    }
}
