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

final class SplitMergeTests: XCTestCase {

    func testSplitMergeMatchesSequential() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 4)

        let data = 100
        let k = 8
        let split: (Int, Int, Int) -> Int = { value, _, index in value + index }
        let body: (Int) -> Int = { $0 * $0 }
        let merge: ([Int]) -> Int = { $0.reduce(0, +) }

        let handle = runtime.spawnSplit(
            data: data, splitFactor: k,
            split: split, merge: merge, body
        )
        let parallel = handle.join()

        let sequential = merge((0..<k).map { body(split(data, k, $0)) })
        XCTAssertEqual(parallel, sequential)

        runtime.terminate()
    }

    func testSplitFactorOne() {
        let runtime = Coltrane.shared
        runtime.initialize(maxVPs: 2)
        let h = runtime.spawnSplit(
            data: 5, splitFactor: 1,
            split: { v, _, _ in v }, merge: { $0[0] }, { $0 + 1 }
        )
        XCTAssertEqual(h.join(), 6)
        runtime.terminate()
    }
}
