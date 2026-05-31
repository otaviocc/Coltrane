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

// MergeSortDemo — parallel merge sort computed three ways, for comparison:
//
//   1. Plain recursion        — split, recurse, merge on one thread.
//   2. Coltrane spawnSplit    — fan each level into two halves and merge their
//                               sorted results on join (the split/merge primitive).
//   3. Swift async/await      — `async let` on each half.
//
// Unlike Fibonacci, this is divide-and-conquer over *data*: each level copies and
// merges arrays, so the inherently sequential top-level merges cap the speedup
// (a textbook trait of simple parallel merge sort, not of Coltrane).
//
// Usage: MergeSortDemo [n] [maxVPs] [cutoff]   (defaults: 1_000_000, 8, 16_384)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

/// Below this many elements, sort sequentially — small chunks aren't worth the
/// scheduling overhead. Set once from CLI args before any task runs.
nonisolated(unsafe) var cutoff = 16384

/// Merge two already-sorted runs into one sorted array.
func mergeRuns(_ x: [Int], _ y: [Int]) -> [Int] {
    var out = [Int]()
    out.reserveCapacity(x.count + y.count)
    var i = 0, j = 0
    while i < x.count, j < y.count {
        if x[i] <= y[j] { out.append(x[i])
            i += 1
        } else { out.append(y[j])
            j += 1
        }
    }
    if i < x.count { out.append(contentsOf: x[i...]) }
    if j < y.count { out.append(contentsOf: y[j...]) }
    return out
}

// MARK: 1. Plain recursion

func mergeSortSequential(_ a: [Int]) -> [Int] {
    if a.count <= cutoff { return a.sorted() }
    let mid = a.count / 2
    return mergeRuns(mergeSortSequential(Array(a[..<mid])), mergeSortSequential(Array(a[mid...])))
}

// MARK: 2. Coltrane spawnSplit

func mergeSortColtrane(_ a: [Int]) -> [Int] {
    if a.count <= cutoff { return a.sorted() }
    let handle = Coltrane.shared.spawnSplit(
        data: a,
        splitFactor: 2,
        split: { arr, _, index in
            let mid = arr.count / 2
            return index == 0 ? Array(arr[..<mid]) : Array(arr[mid...])
        },
        merge: { halves in mergeRuns(halves[0], halves[1]) },
        { mergeSortColtrane($0) }
    )
    return handle.join()
}

// MARK: 3. Swift async/await

func mergeSortAsync(_ a: [Int]) async -> [Int] {
    if a.count <= cutoff { return a.sorted() }
    let mid = a.count / 2
    async let left = mergeSortAsync(Array(a[..<mid]))
    async let right = mergeSortAsync(Array(a[mid...]))
    return await mergeRuns(left, right)
}

// MARK: Driver

func splitmix64(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, _ result: [Int], since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ n=%d  (%.1f ms)", padded, result.count, elapsedMilliseconds(since: start)))
}

let n = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1_000_000) : 1_000_000
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
if CommandLine.arguments.count > 3, let c = Int(CommandLine.arguments[3]) { cutoff = c }
print("n=\(n)  maxVPs=\(maxVPs)  cutoff=\(cutoff)")

// Deterministic input (same array for every approach).
let input = (0..<n).map { Int(truncatingIfNeeded: splitmix64(UInt64($0))) }
let reference = input.sorted()

// 1. Plain recursion
let seqStart = Date()
let sequential = mergeSortSequential(input)
report("sequential", sequential, since: seqStart)

// 2. Coltrane spawnSplit
Coltrane.shared.initialize(maxVPs: maxVPs)
let coltraneStart = Date()
let coltrane = mergeSortColtrane(input)
report("coltrane (\(maxVPs) VP)", coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await mergeSortAsync(input)
report("async/await", asynchronous, since: asyncStart)

precondition(
    sequential == reference && coltrane == reference && asynchronous == reference,
    "all three approaches must produce the fully sorted array"
)
