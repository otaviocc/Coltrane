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

// FiboDemo — the same recursive Fibonacci computed three ways, for
// comparison:
//
//   1. Plain recursion        — a single thread, no scheduling.
//   2. Coltrane spawn/join    — the work-helping runtime mapping the task DAG
//                               onto Virtual Processors.
//   3. Swift async/await      — structured concurrency (`async let`) on the
//                               cooperative thread pool.
//
// All three describe the *same* concurrency; only the runtime differs. The
// result is identical regardless of approach or VP count.
//
// Usage: FiboDemo [n] [maxVPs] [cutoff]   (defaults: n = 35, maxVPs = 4, cutoff = 20)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

/// Below this size, stop subdividing and just recurse sequentially — otherwise
/// scheduling overhead dwarfs the work (true for every approach). Larger cutoff
/// = coarser tasks = less scheduling overhead, fewer of them.
///
/// `nonisolated(unsafe)`: set once from the CLI args before any task runs, then
/// only read — so the demo's nonisolated recursive functions may reference it.
nonisolated(unsafe) var cutoff = 20

// MARK: 1. Plain recursion

func fibonacciSequential(_ n: Int) -> Int {
    guard n > 1 else { return n }
    return fibonacciSequential(n - 1) + fibonacciSequential(n - 2)
}

// MARK: 2. Coltrane spawn/join

func fibonacciColtrane(_ n: Int) -> Int {
    guard n > 1 else { return n }
    if n <= cutoff { return fibonacciSequential(n) }

    let a = Coltrane.shared.spawn { fibonacciColtrane(n - 1) }
    let b = Coltrane.shared.spawn { fibonacciColtrane(n - 2) }
    return a.join() + b.join()
}

// MARK: 3. Swift async/await

func fibonacciAsync(_ n: Int) async -> Int {
    guard n > 1 else { return n }
    if n <= cutoff { return fibonacciSequential(n) }

    async let a = fibonacciAsync(n - 1)
    async let b = fibonacciAsync(n - 2)
    return await a + b
}

// MARK: Driver

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, result: Int, since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ fib(%d) = %d  (%.1f ms)", padded, n, result, elapsedMilliseconds(since: start)))
}

let n = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 35) : 35
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 4) : 4
if CommandLine.arguments.count > 3, let c = Int(CommandLine.arguments[3]) { cutoff = c }
print("n=\(n)  maxVPs=\(maxVPs)  cutoff=\(cutoff)")

// 1. Plain recursion
let seqStart = Date()
let sequential = fibonacciSequential(n)
report("sequential", result: sequential, since: seqStart)

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
let coltraneStart = Date()
let coltrane = Coltrane.shared.spawn { fibonacciColtrane(n) }.join()
report("coltrane (\(maxVPs) VP)", result: coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await fibonacciAsync(n)
report("async/await", result: asynchronous, since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must agree"
)
