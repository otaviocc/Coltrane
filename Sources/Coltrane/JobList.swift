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

/// A thread-safe, ordered list of jobs — one level of the task graph.
///
/// Backed by an array guarded by a recursive lock. The lock is recursive
/// because `searchJobs` walks a parent list and recurses into a child list
/// while still holding locks. Use `lock()`/`unlock()` to make a read followed
/// by a structural change atomic with respect to other processors.
final class JobList: @unchecked Sendable {

    // MARK: - Properties

    private let _lock = NSRecursiveLock()
    private var storage: [AnyJob] = []

    /// The number of jobs in the list.
    var count: Int {
        _lock.lock()
        defer { _lock.unlock() }
        return storage.count
    }

    /// Whether the list contains no jobs.
    var isEmpty: Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return storage.isEmpty
    }

    /// A newest-first copy of the list — the order the scheduler searches in.
    var reversedSnapshot: [AnyJob] {
        _lock.lock()
        defer { _lock.unlock() }
        return storage.reversed()
    }

    /// An insertion-order copy of the list.
    var snapshot: [AnyJob] {
        _lock.lock()
        defer { _lock.unlock() }
        return storage
    }

    // MARK: - Public

    /// Acquires the list's lock. Pair with `unlock()`; the lock is recursive.
    func lock() {
        _lock.lock()
    }

    /// Releases the list's lock.
    func unlock() {
        _lock.unlock()
    }

    /// Appends `job` to the end of the list and records this list as its parent.
    func append(_ job: AnyJob) {
        _lock.lock()
        storage.append(job)
        job.parentList = self
        _lock.unlock()
    }

    /// Walks the list newest-first under the lock, returning the first non-nil
    /// result of `match`. Avoids copying the backing array on the search hot
    /// path; the lock is held for the whole walk (and any recursion `match`
    /// performs into child lists).
    func firstMatchReversed(_ match: (AnyJob) -> AnyJob?) -> AnyJob? {
        _lock.lock()
        defer { _lock.unlock() }
        var index = storage.count - 1
        while index >= 0 {
            if let found = match(storage[index]) { return found }
            index -= 1
        }
        return nil
    }

    /// Removes every job from the list in one locked operation.
    func removeAll() {
        _lock.lock()
        storage.removeAll()
        _lock.unlock()
    }

    /// Removes the first job matching `predicate`, returning whether one was
    /// found and removed.
    @discardableResult
    func removeFirstMatching(_ predicate: (AnyJob) -> Bool) -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        guard let idx = storage.firstIndex(where: predicate) else { return false }
        storage.remove(at: idx)
        return true
    }

    /// Removes `job` from the list.
    ///
    /// When `reparentingChildren` is `true`, any of the job's children that
    /// outlived it are spliced into the job's former position and re-parented
    /// onto this list, so they remain reachable. In the normal join flow a
    /// job's children have already completed and removed themselves, making
    /// this a safety net.
    func remove(_ job: AnyJob, reparentingChildren: Bool) {
        _lock.lock()
        defer { _lock.unlock() }
        guard let idx = storage.firstIndex(where: { $0 === job }) else { return }

        if reparentingChildren {
            let survivors = job.children.snapshot
            if !survivors.isEmpty {
                storage.insert(contentsOf: survivors, at: idx)
                for child in survivors {
                    child.parentList = self
                }
                job.children.removeAll()
            }
        }
        if let removeIdx = storage.firstIndex(where: { $0 === job }) {
            storage.remove(at: removeIdx)
        }
    }
}
