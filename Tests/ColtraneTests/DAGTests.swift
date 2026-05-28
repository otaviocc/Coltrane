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

final class DAGTests: XCTestCase {

    func testListAppendAndReverseOrder() {
        let list = JobList()
        let a = Job<Int>(id: 1, options: .init()) { 1 }
        let b = Job<Int>(id: 2, options: .init()) { 2 }
        let c = Job<Int>(id: 3, options: .init()) { 3 }
        list.append(a)
        list.append(b)
        list.append(c)

        XCTAssertEqual(list.count, 3)
        // Newest-first traversal order (list_for_each_prev).
        XCTAssertEqual(list.reversedSnapshot.map(\.id), [3, 2, 1])
        // append records the containing list on each node.
        XCTAssertIdentical(a.parentList, list)
    }

    func testRemoveFirstMatching() {
        let list = JobList()
        let a = Job<Int>(id: 10, options: .init()) { 0 }
        let b = Job<Int>(id: 11, options: .init()) { 0 }
        list.append(a)
        list.append(b)

        XCTAssertTrue(list.removeFirstMatching { $0.id == 10 })
        XCTAssertEqual(list.snapshot.map(\.id), [11])
        XCTAssertFalse(list.removeFirstMatching { $0.id == 999 })
    }

    func testRemoveReparentsSurvivingChildren() {
        let root = JobList()
        let parent = Job<Int>(id: 20, options: .init()) { 0 }
        let child1 = Job<Int>(id: 21, options: .init()) { 0 }
        let child2 = Job<Int>(id: 22, options: .init()) { 0 }
        root.append(parent)
        parent.children.append(child1)
        parent.children.append(child2)

        root.remove(parent, reparentingChildren: true)

        // Parent gone; children spliced into the root list at its old position.
        XCTAssertEqual(Set(root.snapshot.map(\.id)), [21, 22])
        XCTAssertIdentical(child1.parentList, root)
    }

    func testSpawnAttachesChildToCurrentJob() throws {
        let runtime = Runtime.shared
        runtime.initialize(maxVPs: 1) // single VP: everything runs inline on main
        runtime.removeJobsEnabled = false

        // The root job, while running, spawns a child. With removal disabled we
        // can inspect that the child landed under the parent in the DAG.
        var childId: UInt64 = .max
        let handle = runtime.spawn { () -> Int in
            let child = runtime.spawn { 7 }
            childId = child.job.id
            return child.join()
        }
        XCTAssertEqual(handle.join(), 7)

        // The parent (root) should carry the child in its children list.
        let roots = runtime.rootList.snapshot
        let parent = roots.first { $0.id == handle.job.id }
        XCTAssertNotNil(parent)
        XCTAssertTrue(try XCTUnwrap(parent?.children.snapshot.contains { $0.id == childId }))

        runtime.removeJobsEnabled = true
        runtime.terminate()
    }
}
