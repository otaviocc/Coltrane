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

func fibonacci(_ n: Int) -> Int {
    guard n > 1 else { return n }
    if n <= 20 { return fibonacci(n - 1) + fibonacci(n - 2) }
    let a = Coltrane.shared.spawn { fibonacci(n - 1) }
    let b = Coltrane.shared.spawn { fibonacci(n - 2) }
    return a.join() + b.join()
}

final class FibonacciTests: XCTestCase {

    func testFibonacci35IndependentOfVPCount() {
        for vps in [1, 2, 4, 8] {
            let runtime = Coltrane.shared
            runtime.initialize(maxVPs: vps)
            let result = runtime.spawn { fibonacci(35) }.join()
            XCTAssertEqual(result, 9_227_465, "fibonacci(35) on \(vps) VPs")
            let leaked = runtime.terminate()
            XCTAssertEqual(leaked, 0, "all jobs should be .joined after terminate (\(vps) VPs)")
        }
    }

    func testMultiVPNotSlowerThanSingleVP() {
        /// Coarse-grained scaling smoke test (not a strict speedup guarantee).
        func wall(_ vps: Int) -> TimeInterval {
            let runtime = Coltrane.shared
            runtime.initialize(maxVPs: vps)
            let start = Date()
            _ = runtime.spawn { fibonacci(34) }.join()
            let elapsed = Date().timeIntervalSince(start)
            runtime.terminate()
            return elapsed
        }
        let single = wall(1)
        let multi = wall(max(2, ProcessInfo.processInfo.activeProcessorCount))
        // Allow generous slack; we only assert multi-VP isn't dramatically worse.
        XCTAssertLessThan(
            multi,
            single * 1.5,
            "multi-VP (\(multi)s) should not be much slower than single-VP (\(single)s)"
        )
    }
}
