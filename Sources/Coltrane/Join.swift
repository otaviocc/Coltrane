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

/// Synchronization: the work-helping join and the passive fetch.
extension Runtime {

    // MARK: - Public

    /// Actively drives `job` to completion, then marks it joined and — once its
    /// join count is exhausted — removes it from the graph.
    ///
    /// Rather than blocking, the calling processor runs `job` itself if it is
    /// still unclaimed, otherwise helps with other pending work, parking only
    /// briefly when there is nothing to do.
    func join(_ job: AnyJob) {
        helpUntilDone(job, vp: currentVP())

        job.completion.lock()
        job.status = .joined
        job.options.maxJoins -= 1
        let shouldRemove = job.options.maxJoins <= 0 && removeJobsEnabled
        job.completion.unlock()

        if shouldRemove {
            job.parentList?.remove(job, reparentingChildren: true)
        }
    }

    /// Waits passively for `job` to finish without running any work, then marks
    /// it joined. Leaves the job in the graph; relies on other processors to
    /// run it.
    func fetch(_ job: AnyJob) {
        while !isComplete(job) {
            waitBriefly(for: job)
        }
        job.completion.lock()
        job.status = .joined
        job.completion.unlock()
    }

    /// Whether `job` has finished (`.done` or already `.joined`).
    func isComplete(_ job: AnyJob) -> Bool {
        job.completion.lock()
        defer { job.completion.unlock() }
        return job.isFinishedLocked
    }

    // MARK: - Private

    private func helpUntilDone(_ target: AnyJob, vp: VirtualProcessor?) {
        while true {
            if isComplete(target) { return }

            if let vp {
                if claim(target, for: vp) {
                    executeJob(target, on: vp)
                    continue
                }
                if let work = findHelpWork(for: target, vp: vp) {
                    executeJob(work, on: vp)
                    continue
                }
            }
            waitBriefly(for: target)
        }
    }

    private func waitBriefly(for job: AnyJob) {
        job.completion.lock()
        if !job.isFinishedLocked {
            job.completion.wait(until: Date().addingTimeInterval(Runtime.idlePollInterval))
        }
        job.completion.unlock()
    }
}
