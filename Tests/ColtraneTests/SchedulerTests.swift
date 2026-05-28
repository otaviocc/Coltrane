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
        let runtime = Runtime.shared
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
        let runtime = Runtime.shared
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
        let runtime = Runtime.shared
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

    func testEachHelpingStrategyProducesCorrectResult() {
        // Result must be independent of the search policy.
        for strategy in [Runtime.HelpingStrategy.anywhere, .currentSubtree, .joinedSubtree] {
            let runtime = Runtime.shared
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
    let a = Runtime.shared.spawn { sumTree(depth - 1) }
    let b = Runtime.shared.spawn { sumTree(depth - 1) }
    return a.join() + b.join()
}
