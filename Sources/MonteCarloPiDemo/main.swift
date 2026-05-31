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

// MonteCarloPiDemo — estimate π by Monte Carlo, three ways:
//
//   1. Sequential   — count points in the quarter disk on one thread.
//   2. Coltrane     — samples split into chunks, one spawn/join per chunk.
//   3. async/await  — one child task per chunk in a TaskGroup.
//
// This is a parallel *reduction*: each chunk counts its hits, the counts are
// summed. Each sample's coordinates come from a counter-based RNG keyed by the
// global sample index (not a per-thread stream), so the hit count is identical
// no matter how the samples are chunked — the estimate is bit-for-bit
// reproducible across all three methods, which they assert.
//
// Usage: MonteCarloPiDemo [samples] [maxVPs]   (defaults: 100_000_000, 8)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

/// SplitMix64: hash the index into well-mixed bits, so sample `i` is the same
/// regardless of how the work is split. The constants are the published
/// SplitMix64 finalizer — 0x9E37…C15 is the golden-ratio odd increment, the two
/// multipliers plus the 30/27/31 xor-shifts are its avalanche mix.
func splitmix64(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// Top 53 bits → a Double in [0, 1). 2^53 = 9_007_199_254_740_992 is the largest
/// integer a Double represents exactly, so the quotient is uniform.
func unitDouble(_ bits: UInt64) -> Double {
    Double(bits >> 11) * (1.0 / 9_007_199_254_740_992.0)
}

/// Count, over `range`, the samples that fall inside the unit quarter disk —
/// points in the unit square with x² + y² < 1. The fraction inside tends to π/4.
func insideCount(_ range: Range<Int>) -> Int {
    var hits = 0
    for i in range {
        // Two independent draws per sample (keys 2i and 2i+1).
        let x = unitDouble(splitmix64(UInt64(i) &* 2))
        let y = unitDouble(splitmix64(UInt64(i) &* 2 &+ 1))
        if x * x + y * y < 1.0 { hits += 1 }
    }
    return hits
}

func chunkRanges(_ total: Int, count: Int) -> [Range<Int>] {
    let chunks = max(1, min(count, total))
    let size = (total + chunks - 1) / chunks
    var ranges: [Range<Int>] = []
    var lo = 0
    while lo < total {
        ranges.append(lo..<min(total, lo + size))
        lo += size
    }
    return ranges
}

// MARK: 2. Coltrane spawn/join

func insideColtrane(_ samples: Int, chunks: Int) -> Int {
    let handles = chunkRanges(samples, count: chunks).map { range in
        Coltrane.shared.spawn { insideCount(range) }
    }
    return handles.reduce(0) { $0 + $1.join() }
}

// MARK: 3. Swift async/await

func insideAsync(_ samples: Int, chunks: Int) async -> Int {
    await withTaskGroup(of: Int.self) { group in
        for range in chunkRanges(samples, count: chunks) {
            group.addTask { insideCount(range) }
        }
        var total = 0
        for await hits in group {
            total += hits
        }
        return total
    }
}

// MARK: Driver

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, hits: Int, samples: Int, since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    let estimate = 4.0 * Double(hits) / Double(samples)
    print(String(format: "%@ π ≈ %.6f  (%.1f ms)", padded, estimate, elapsedMilliseconds(since: start)))
}

let samples = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 100_000_000) : 100_000_000
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let chunks = maxVPs * 8
print("samples=\(samples)  maxVPs=\(maxVPs)  chunks=\(chunks)")

// 1. Sequential
let seqStart = Date()
let sequential = insideCount(0..<samples)
report("sequential", hits: sequential, samples: samples, since: seqStart)

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat reduction: help with any pending chunk
let coltraneStart = Date()
let coltrane = insideColtrane(samples, chunks: chunks)
report("coltrane (\(maxVPs) VP)", hits: coltrane, samples: samples, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await insideAsync(samples, chunks: chunks)
report("async/await", hits: asynchronous, samples: samples, since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must count the same number of hits"
)
