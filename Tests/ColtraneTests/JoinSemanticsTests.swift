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

final class JoinSemanticsTests: XCTestCase {

    func testJoinUnassignedExecutesInline() {
        let runtime = Runtime.shared
        runtime.initialize(maxVPs: 1) // forces unassigned + inline execution
        let h = runtime.spawn { 21 + 21 }
        XCTAssertEqual(h.join(), 42)
        runtime.terminate()
    }

    func testJoinReturnsResultWhenAlreadyDone() {
        let runtime = Runtime.shared
        runtime.initialize(maxVPs: 1)
        let h = runtime.spawn { 99 }
        XCTAssertEqual(h.join(), 99) // first join executes + completes
        XCTAssertTrue(h.isComplete)
        runtime.terminate()
    }

    func testMaxJoinsKeepsJobUntilExhausted() {
        let runtime = Runtime.shared
        runtime.initialize(maxVPs: 1)
        runtime.removeJobsEnabled = true

        var opts = JobOptions()
        opts.maxJoins = 2
        let h = runtime.spawn(options: opts) { 5 }

        XCTAssertEqual(h.join(), 5) // maxJoins 2 -> 1, not removed
        XCTAssertEqual(h.job.options.maxJoins, 1)
        XCTAssertEqual(h.join(), 5) // maxJoins 1 -> 0, removed
        XCTAssertEqual(h.job.options.maxJoins, 0)
        runtime.terminate()
    }

    func testFetchWaitsWithoutRemoving() {
        let runtime = Runtime.shared
        runtime.initialize(maxVPs: 4)
        let h = runtime.spawn { 123 }
        XCTAssertEqual(h.fetch(), 123)
        XCTAssertTrue(h.isComplete)
        runtime.terminate()
    }

    func testAssignedToExecutingFallThroughUnderContention() {
        // Many coarse tasks across several VPs exercise the path where a joined
        // job is assigned-to-another-VP / executing: join must help + wait, not
        // deadlock, and still return the correct aggregate.
        let runtime = Runtime.shared
        runtime.initialize(maxVPs: 8)
        let h = runtime.spawn { sumTree(14) }
        XCTAssertEqual(h.join(), 1 << 14)
        runtime.terminate()
    }
}
