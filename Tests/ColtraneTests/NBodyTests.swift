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

private struct V: Equatable {

    var x: Double
    var y: Double
}

private final class Node: @unchecked Sendable {

    let cx, cy, half: Double
    var mass = 0.0, comX = 0.0, comY = 0.0
    var body: Int?
    var kids: [Node?] = [nil, nil, nil, nil]
    init(_ cx: Double, _ cy: Double, _ half: Double) {
        self.cx = cx
        self.cy = cy
        self.half = half
    }

    func quad(_ x: Double, _ y: Double) -> Int {
        (x >= cx ? 1 : 0) | (y >= cy ? 2 : 0)
    }

    func kid(_ q: Int) -> Node {
        if let k = kids[q] { return k }
        let h = half / 2
        let k = Node(cx + (q & 1 == 1 ? h : -h), cy + (q & 2 == 2 ? h : -h), h)
        kids[q] = k
        return k
    }

    func insert(_ i: Int, _ px: Double, _ py: Double, _ pts: [(Double, Double)]) {
        if mass == 0, body == nil, kids.allSatisfy({ $0 == nil }) {
            body = i
            mass = 1
            comX = px
            comY = py
            return
        }
        if let j = body { body = nil
            kid(quad(pts[j].0, pts[j].1)).insert(j, pts[j].0, pts[j].1, pts)
        }
        let t = mass + 1
        comX = (comX * mass + px) / t
        comY = (comY * mass + py) / t
        mass = t
        kid(quad(px, py)).insert(i, px, py, pts)
    }
}

private func accel(_ i: Int, _ px: Double, _ py: Double, _ node: Node) -> V {
    if node.mass == 0 { return V(x: 0, y: 0) }
    let dx = node.comX - px, dy = node.comY - py, d2 = dx * dx + dy * dy
    func point() -> V {
        let s = d2 + 1e-6
        let inv = node.mass / (s * s.squareRoot())
        return V(x: dx * inv, y: dy * inv)
    }
    if let j = node.body { return j == i ? V(x: 0, y: 0) : point() }
    let size = 2 * node.half
    if size * size < 0.25 * d2 { return point() }
    var ax = 0.0, ay = 0.0
    for q in 0..<4 where node.kids[q] != nil {
        let a = accel(i, px, py, node.kids[q]!)
        ax += a.x
        ay += a.y
    }
    return V(x: ax, y: ay)
}

final class NBodyTests: XCTestCase {

    func testParallelForcesMatchSequential() {
        // Deterministic points.
        var state: UInt64 = 0xDEAD_BEEF
        func rnd() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(state >> 11) / 9_007_199_254_740_992.0
        }
        let n = 500
        let pts: [(Double, Double)] = (0..<n).map { _ in (rnd() * 2 - 1, rnd() * 2 - 1) }

        let root = Node(0, 0, 1.01)
        for i in 0..<n {
            root.insert(i, pts[i].0, pts[i].1, pts)
        }

        let sequential = (0..<n).map { accel($0, pts[$0].0, pts[$0].1, root) }

        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 4)
        runtime.helpingStrategy = .anywhere
        let chunkSize = 37
        var handles: [JobHandle<[V]>] = []
        var lo = 0
        while lo < n {
            let range = lo..<min(n, lo + chunkSize)
            handles.append(runtime.spawn { range.map { accel($0, pts[$0].0, pts[$0].1, root) } })
            lo += chunkSize
        }
        let parallel = handles.flatMap { $0.join() }
        XCTAssertEqual(runtime.terminate(), 0)

        XCTAssertEqual(parallel, sequential) // exact, bit-for-bit
    }
}
