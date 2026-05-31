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

// BlackScholesDemo — price a European call by Monte Carlo, three ways:
//
//   1. Sequential   — average discounted payoffs on one thread.
//   2. Coltrane     — samples split into chunks, one spawn/join per chunk.
//   3. async/await  — one child task per chunk in a TaskGroup.
//
// A parallel reduction, like the π demo, but over floating-point payoffs. To
// stay bit-identical (floating-point addition isn't associative), every method
// produces the *same* per-chunk partial sums — each from a counter-based RNG
// keyed by the global sample index — and combines them in the same chunk order.
// So the estimated price is reproducible to the last bit across all three, which
// they assert. The closed-form Black–Scholes price is printed for reference.
//
// Usage: BlackScholesDemo [samples] [maxVPs]   (defaults: 100_000_000, 8)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

// Option / market parameters.
let spot = 100.0
let strike = 100.0
let rate = 0.05
let vol = 0.20
let maturity = 1.0

let drift = (rate - 0.5 * vol * vol) * maturity
let volSqrtT = vol * maturity.squareRoot()
let discount = exp(-rate * maturity)

/// Counter-based RNG: a hash of the index, identical regardless of chunking.
func splitmix64(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

func unitHalfOpen(_ bits: UInt64) -> Double {
    Double(bits >> 11) * (1.0 / 9_007_199_254_740_992.0)
}

func unitOpen(_ bits: UInt64) -> Double {
    (Double(bits >> 11) + 0.5) * (1.0 / 9_007_199_254_740_992.0)
}

/// Discounted call payoff for sample `i`: a Box–Muller normal drives one step of
/// geometric Brownian motion to maturity.
func payoff(_ i: Int) -> Double {
    let u1 = unitOpen(splitmix64(UInt64(i) &* 2))
    let u2 = unitHalfOpen(splitmix64(UInt64(i) &* 2 &+ 1))
    let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    let terminal = spot * exp(drift + volSqrtT * z)
    return max(terminal - strike, 0)
}

func partialSum(_ range: Range<Int>) -> Double {
    var total = 0.0
    for i in range {
        total += payoff(i)
    }
    return total
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

/// Combine per-chunk partial sums into a price. Identical grouping for every
/// method keeps the result bit-for-bit reproducible.
func price(_ partials: [Double], samples: Int) -> Double {
    discount * partials.reduce(0, +) / Double(samples)
}

// MARK: 2. Coltrane spawn/join

func partialsColtrane(_ ranges: [Range<Int>]) -> [Double] {
    ranges.map { range in Coltrane.shared.spawn { partialSum(range) } }.map { $0.join() }
}

// MARK: 3. Swift async/await

func partialsAsync(_ ranges: [Range<Int>]) async -> [Double] {
    await withTaskGroup(of: (Int, Double).self) { group in
        for (index, range) in ranges.enumerated() {
            group.addTask { (index, partialSum(range)) }
        }
        var partials = [Double](repeating: 0, count: ranges.count)
        for await (index, sum) in group {
            partials[index] = sum
        }
        return partials
    }
}

// MARK: Reference

func normalCDF(_ x: Double) -> Double {
    0.5 * erfc(-x / 2.0.squareRoot())
}

func analyticCall() -> Double {
    let d1 = (log(spot / strike) + (rate + 0.5 * vol * vol) * maturity) / volSqrtT
    let d2 = d1 - volSqrtT
    return spot * normalCDF(d1) - strike * discount * normalCDF(d2)
}

// MARK: Driver

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, _ value: Double, since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ call ≈ %.6f  (%.1f ms)", padded, value, elapsedMilliseconds(since: start)))
}

let samples = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 100_000_000) : 100_000_000
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let chunks = maxVPs * 8
let ranges = chunkRanges(samples, count: chunks)
print("samples=\(samples)  maxVPs=\(maxVPs)  chunks=\(chunks)")
print(String(format: "analytic         call = %.6f", analyticCall()))

// 1. Sequential
let seqStart = Date()
let sequential = price(ranges.map(partialSum), samples: samples)
report("sequential", sequential, since: seqStart)

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat reduction: help with any pending chunk
let coltraneStart = Date()
let coltrane = price(partialsColtrane(ranges), samples: samples)
report("coltrane (\(maxVPs) VP)", coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await price(partialsAsync(ranges), samples: samples)
report("async/await", asynchronous, since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must produce the identical price"
)
