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

// MatMulDemo — dense square matrix multiply C = A·B, three ways:
//
//   1. Sequential   — compute every output row on one thread.
//   2. Coltrane     — output rows split into bands, one spawn/join per band.
//   3. async/await  — one child task per band in a TaskGroup.
//
// The classic fork/join throughput benchmark. Work is partitioned over *bands of
// output rows* — coarse, uniform-cost jobs whose count scales with the VP count
// (`chunks = maxVPs * 8`), the shape Coltrane oversubscribes best. Each band is
// independent (it reads all of A and B, writes only its own rows of C), so the
// functional style fits: every task returns its rows and the driver concatenates
// them in order.
//
// Inside a band the kernel is cache-*blocked* (the "tiled" part): it walks
// TILE×TILE blocks of the output and the shared dimension to keep the working set
// in cache. Crucially the inner accumulation order is unchanged — for every
// element C[i][j] the products are summed in ascending-k order exactly as a naive
// triple loop would. Floating-point addition isn't associative, so this is what
// keeps all three methods bit-for-bit identical regardless of how rows are
// chunked; they assert it, and print a checksum (Σ C) for reference.
//
// Usage: MatMulDemo [n] [maxVPs]   (defaults: 1024, 8)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

let n = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1024) : 1024
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let chunks = maxVPs * 8
let tile = 64 // cache-blocking factor for the i/j/k loops

/// SplitMix64 finalizer: hash an index into well-mixed bits so the input matrices
/// are deterministic and identical across runs. 0x9E37…C15 is the golden-ratio
/// odd increment; the multipliers plus the 30/27/31 xor-shifts are the avalanche
/// mix.
func splitmix64(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// Top 53 bits → a Double in [0, 1). 2^53 is the largest integer a Double holds
/// exactly, so the quotient is uniform — and bounded, which keeps the products
/// well-scaled.
func unitHalfOpen(_ bits: UInt64) -> Double {
    Double(bits >> 11) * (1.0 / 9_007_199_254_740_992.0)
}

// Input matrices, flat row-major (matA[i*n + j]). Read-only once built, so every
// VP can touch them concurrently. B is keyed off a disjoint hash range from A.
let matA: [Double] = (0..<(n * n)).map { unitHalfOpen(splitmix64(UInt64($0))) }
let matB: [Double] = (0..<(n * n)).map { unitHalfOpen(splitmix64(UInt64($0) &+ UInt64(n) &* UInt64(n))) }

/// Compute rows `rows` of C = A·B and return them flat (length `rows.count * n`),
/// indexed `[(i - rows.lowerBound) * n + j]`.
///
/// Cache-blocked `ikj` walk: for a fixed output element the products land in
/// ascending-k order (kb blocks ascending, k ascending within each), so the sum
/// is bit-identical to the naive triple loop — only the memory access pattern
/// changes. Reading one `matA[ai + k]` and sweeping a contiguous j-block of both
/// matB and the output row is the hot, vectorizable inner loop.
func computeBand(_ rows: Range<Int>) -> [Double] {
    let r0 = rows.lowerBound
    var c = [Double](repeating: 0, count: rows.count * n)
    c.withUnsafeMutableBufferPointer { c in
        matA.withUnsafeBufferPointer { a in
            matB.withUnsafeBufferPointer { b in
                for i in rows {
                    let ci = (i - r0) * n
                    let ai = i * n
                    var jb = 0
                    while jb < n {
                        let jHi = min(jb + tile, n)
                        var kb = 0
                        while kb < n {
                            let kHi = min(kb + tile, n)
                            for k in kb..<kHi {
                                let aik = a[ai + k]
                                let bk = k * n
                                for j in jb..<jHi {
                                    c[ci + j] += aik * b[bk + j]
                                }
                            }
                            kb += tile
                        }
                        jb += tile
                    }
                }
            }
        }
    }
    return c
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

/// Stitch ordered per-band row blocks into the full C matrix.
func assemble(_ bands: [[Double]]) -> [Double] {
    var c = [Double]()
    c.reserveCapacity(n * n)
    for band in bands {
        c.append(contentsOf: band)
    }
    return c
}

// MARK: 2. Coltrane spawn/join

func multiplyColtrane(_ ranges: [Range<Int>]) -> [Double] {
    assemble(ranges.map { range in Coltrane.shared.spawn { computeBand(range) } }.map { $0.join() })
}

// MARK: 3. Swift async/await

func multiplyAsync(_ ranges: [Range<Int>]) async -> [Double] {
    let bands = await withTaskGroup(of: (Int, [Double]).self) { group in
        for (index, range) in ranges.enumerated() {
            group.addTask { (index, computeBand(range)) }
        }
        var result = [[Double]](repeating: [], count: ranges.count)
        for await (index, band) in group {
            result[index] = band
        }
        return result
    }
    return assemble(bands)
}

// MARK: Driver

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, _ checksum: Double, since start: Date) {
    let ms = elapsedMilliseconds(since: start)
    let gflops = 2.0 * Double(n) * Double(n) * Double(n) / (ms / 1000) / 1e9
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ Σ ≈ %.6f  (%.1f ms, %.2f GFLOP/s)", padded, checksum, ms, gflops))
}

let ranges = chunkRanges(n, count: chunks)
print("n=\(n)  maxVPs=\(maxVPs)  chunks=\(chunks)  tile=\(tile)")

// 1. Sequential
let seqStart = Date()
let sequential = assemble(ranges.map(computeBand))
report("sequential", sequential.reduce(0, +), since: seqStart)

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat fan-out: help with any pending band
let coltraneStart = Date()
let coltrane = multiplyColtrane(ranges)
report("coltrane (\(maxVPs) VP)", coltrane.reduce(0, +), since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await multiplyAsync(ranges)
report("async/await", asynchronous.reduce(0, +), since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must produce the identical matrix"
)
