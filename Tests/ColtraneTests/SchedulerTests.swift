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

import XCTest
@testable import Coltrane

// swiftlint:disable identifier_name

final class SchedulerTests: XCTestCase {

    func testSearchClaimsNewestUnassignedFirst() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 1)

        let list = JobList()
        let older = Job<Int>(id: 1, options: .init()) { 0 }
        let newer = Job<Int>(id: 2, options: .init()) { 0 }
        older.status = .unassigned
        newer.status = .unassigned
        list.append(older)
        list.append(newer)

        // DFS walks newest-first → claims `newer` first.
        let claimed = runtime.searchJobs(.unassigned, in: list, claimingVP: nil)
        XCTAssertEqual(claimed?.id, 2)
        XCTAssertEqual(claimed?.status, .assigned)

        // Next claim takes the older one.
        let claimed2 = runtime.searchJobs(.unassigned, in: list, claimingVP: nil)
        XCTAssertEqual(claimed2?.id, 1)

        // Nothing left to claim.
        XCTAssertNil(runtime.searchJobs(.unassigned, in: list, claimingVP: nil))
        runtime.terminate()
    }

    func testSearchRecursesIntoChildren() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 1)

        let list = JobList()
        let parent = Job<Int>(id: 1, options: .init()) { 0 }
        parent.status = .assigned // not claimable itself
        let child = Job<Int>(id: 2, options: .init()) { 0 }
        child.status = .unassigned
        list.append(parent)
        parent.children.append(child)

        let claimed = runtime.searchJobs(.unassigned, in: list, claimingVP: nil)
        XCTAssertEqual(claimed?.id, 2)
        runtime.terminate()
    }

    func testMatchById() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 1)

        let list = JobList()
        let a = Job<Int>(id: 41, options: .init()) { 0 }
        let b = Job<Int>(id: 42, options: .init()) { 0 }
        list.append(a)
        list.append(b)

        XCTAssertEqual(runtime.searchJobs(.id(41), in: list, claimingVP: nil)?.id, 41)
        // Matching by id does not change status.
        XCTAssertEqual(a.status, .unassigned)
        XCTAssertNil(runtime.searchJobs(.id(999), in: list, claimingVP: nil))
        runtime.terminate()
    }

    func testClaimAssignsUnassignedJobOnce() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 1)
        let vp = VirtualProcessor(id: 7, isMain: false, runtime: runtime)
        let job = Job<Int>(id: 1, options: .init()) { 0 }

        XCTAssertTrue(runtime.claim(job, for: vp))
        XCTAssertEqual(job.status, .assigned)
        XCTAssertIdentical(job.owner, vp)
        // A second claim fails — no two processors ever run the same job.
        XCTAssertFalse(runtime.claim(job, for: vp))
        runtime.terminate()
    }

    func testClaimRespectsSpecificAffinity() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 1)
        var opts = JobOptions()
        opts.affinity = .specific(2)
        let job = Job<Int>(id: 1, options: opts) { 0 }
        let vp1 = VirtualProcessor(id: 1, isMain: false, runtime: runtime)
        let vp2 = VirtualProcessor(id: 2, isMain: false, runtime: runtime)

        // A non-matching processor cannot claim it; it stays unassigned.
        XCTAssertFalse(runtime.claim(job, for: vp1))
        XCTAssertEqual(job.status, .unassigned)
        // The matching processor can.
        XCTAssertTrue(runtime.claim(job, for: vp2))
        XCTAssertIdentical(job.owner, vp2)
        runtime.terminate()
    }

    func testSpecificAffinityJobRunsAndJoins() {
        // End-to-end: a job pinned to a valid VP id is routed there, runs, and
        // joins to the right result.
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 4) // VP ids 0...3
        var opts = JobOptions()
        opts.affinity = .specific(2)
        let h = runtime.spawn(options: opts) { 6 * 7 }
        XCTAssertEqual(h.join(), 42)
        runtime.terminate()
    }

    func testEachHelpingStrategyProducesCorrectResult() {
        // Result must be independent of the search policy.
        for strategy in [Coltrane.HelpingStrategy.anywhere, .currentSubtree, .joinedSubtree] {
            let runtime = Coltrane.shared
            runtime.initialize(maxVPs: 4)
            runtime.helpingStrategy = strategy
            let h = runtime.spawn { sumTree(12) }
            XCTAssertEqual(h.join(), 1 << 12, "strategy \(strategy)")
            runtime.terminate()
        }
    }
}

/// A coarse fan-out workload: returns 2^depth by spawning two halves.
func sumTree(_ depth: Int) -> Int {
    if depth == 0 { return 1 }
    let a = Coltrane.shared.spawn { sumTree(depth - 1) }
    let b = Coltrane.shared.spawn { sumTree(depth - 1) }
    return a.join() + b.join()
}
