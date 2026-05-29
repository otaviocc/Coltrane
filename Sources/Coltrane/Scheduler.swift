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

/// What `searchJobs` is looking for as it walks the graph.
enum MatchCondition {

    /// Find the job with this identifier, without claiming it.
    case id(UInt64)
    /// Find any unassigned job and atomically claim it for the searching
    /// processor.
    case unassigned
}

/// Work-finding and job execution: the heart of the scheduler.
extension Runtime {

    // MARK: - Public

    /// Searches `list` depth-first, newest-first, for a job matching `match`.
    ///
    /// For `.unassigned`, the matching job is claimed atomically (its status
    /// flips to `.assigned` and its owner is set) before being returned, so two
    /// processors never run the same job. Recurses into each job's children.
    /// Returns `nil` if nothing matches.
    func searchJobs(
        _ match: MatchCondition,
        in list: JobList,
        claimingVP vp: VirtualProcessor?
    ) -> AnyJob? {
        list.firstMatchReversed { entry in
            if claimIfMatches(entry, match, claimingVP: vp) {
                return entry
            }
            if !entry.children.isEmpty {
                return searchJobs(match, in: entry.children, claimingVP: vp)
            }
            return nil
        }
    }

    /// Runs `job` inline on `vp`'s call stack: marks it `.executing`, pushes it
    /// onto the processor's stack so nested spawns attach as its children, runs
    /// it, then pops. A detached job is marked joined and spliced out once done.
    func executeJob(_ job: AnyJob, on vp: VirtualProcessor) {
        job.completion.lock()
        job.status = .executing
        job.completion.unlock()

        vp.jobStack.append(job)
        job.run()
        vp.jobStack.removeLast()

        if job.options.detachState == .detached {
            job.completion.lock()
            job.status = .joined
            job.completion.unlock()
            job.parentList?.remove(job, reparentingChildren: true)
        }
    }

    /// The innermost job currently executing on `vp` — the top of its stack.
    func currentJob(_ vp: VirtualProcessor?) -> AnyJob? {
        vp?.jobStack.last
    }

    /// Finds a pending job for `vp` to help with while it waits on `target`,
    /// searching where the active `helpingStrategy` dictates.
    func findHelpWork(for target: AnyJob, vp: VirtualProcessor) -> AnyJob? {
        switch helpingStrategy {
        case .currentSubtree:
            guard let cur = currentJob(vp) else { return nil }
            return searchJobs(.unassigned, in: cur.children, claimingVP: vp)
        case .joinedSubtree:
            return searchJobs(.unassigned, in: target.children, claimingVP: vp)
        case .anywhere:
            return searchJobs(.unassigned, in: rootList, claimingVP: vp)
        }
    }

    /// Atomically claims an unassigned `job` for `vp` (`.unassigned → .assigned`,
    /// owner set from affinity). Returns `false` if it was already claimed or its
    /// `.specific` affinity excludes `vp`. The single claim path used by both the
    /// worker search and the join helping loop.
    func claim(_ job: AnyJob, for vp: VirtualProcessor?) -> Bool {
        job.completion.lock()
        defer { job.completion.unlock() }
        guard job.status == .unassigned else { return false }
        switch job.affinity {
        case .any:
            job.owner = vp
        case let .specific(logicalId):
            if let vp, vp.id != logicalId { return false }
            job.owner = vp ?? findVP(id: logicalId)
        }
        job.status = .assigned
        return true
    }

    // MARK: - Private

    private func claimIfMatches(
        _ entry: AnyJob,
        _ match: MatchCondition,
        claimingVP vp: VirtualProcessor?
    ) -> Bool {
        switch match {
        case let .id(wanted):
            entry.id == wanted
        case .unassigned:
            claim(entry, for: vp)
        }
    }
}
