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

// NQueensDemo — count the solutions to the N-Queens problem three ways:
//
//   1. Plain recursion        — bitmask backtracking on one thread.
//   2. Coltrane spawn/join    — spawn a task per branch down to a cutoff depth.
//   3. Swift async/await      — one child task per branch in a TaskGroup.
//
// Like Fibonacci this is recursive fork/join, but the branches prune to wildly
// different sizes, so the subtrees are deeply *imbalanced*. That is exactly where
// work-helping earns its keep: idle VPs pull work from whichever branch is still
// busy, rather than a static split leaving some threads idle.
//
// Usage: NQueensDemo [n] [maxVPs] [cutoffDepth]   (defaults: 15, 8, 3)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

/// Low n bits set — the set of board columns. Set once from CLI args.
nonisolated(unsafe) var mask = 0
/// Spawn tasks for rows shallower than this; recurse sequentially below it.
nonisolated(unsafe) var cutoffDepth = 3

// MARK: 1. Plain recursion

/// `ld`/`rd` are the diagonal-attack masks (shifted each row), `col` the used
/// columns. A solution is counted when every column is filled.
func queensSequential(_ ld: Int, _ col: Int, _ rd: Int) -> Int {
    if col == mask { return 1 }
    var count = 0
    var free = ~(ld | col | rd) & mask
    while free != 0 {
        let bit = free & -free
        free -= bit
        count += queensSequential((ld | bit) << 1, col | bit, (rd | bit) >> 1)
    }
    return count
}

// MARK: 2. Coltrane spawn/join

func queensColtrane(_ ld: Int, _ col: Int, _ rd: Int, _ depth: Int) -> Int {
    if col == mask { return 1 }
    if depth >= cutoffDepth { return queensSequential(ld, col, rd) }
    var handles: [JobHandle<Int>] = []
    var free = ~(ld | col | rd) & mask
    while free != 0 {
        let bit = free & -free
        free -= bit
        handles.append(Coltrane.shared.spawn {
            queensColtrane((ld | bit) << 1, col | bit, (rd | bit) >> 1, depth + 1)
        })
    }
    return handles.reduce(0) { $0 + $1.join() }
}

// MARK: 3. Swift async/await

func queensAsync(_ ld: Int, _ col: Int, _ rd: Int, _ depth: Int) async -> Int {
    if col == mask { return 1 }
    if depth >= cutoffDepth { return queensSequential(ld, col, rd) }
    return await withTaskGroup(of: Int.self) { group in
        var free = ~(ld | col | rd) & mask
        while free != 0 {
            let bit = free & -free
            free -= bit
            group.addTask { await queensAsync((ld | bit) << 1, col | bit, (rd | bit) >> 1, depth + 1) }
        }
        var total = 0
        for await branch in group {
            total += branch
        }
        return total
    }
}

// MARK: Driver

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, _ count: Int, since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ solutions = %d  (%.1f ms)", padded, count, elapsedMilliseconds(since: start)))
}

let n = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 15) : 15
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
if CommandLine.arguments.count > 3, let c = Int(CommandLine.arguments[3]) { cutoffDepth = c }
mask = (1 << n) - 1
print("n=\(n)  maxVPs=\(maxVPs)  cutoffDepth=\(cutoffDepth)")

// 1. Plain recursion
let seqStart = Date()
let sequential = queensSequential(0, 0, 0)
report("sequential", sequential, since: seqStart)

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
let coltraneStart = Date()
let coltrane = queensColtrane(0, 0, 0, 0)
report("coltrane (\(maxVPs) VP)", coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await queensAsync(0, 0, 0, 0)
report("async/await", asynchronous, since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must count the same number of solutions"
)
