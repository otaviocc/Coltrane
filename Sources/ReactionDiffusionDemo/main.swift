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

// ReactionDiffusionDemo — a Gray–Scott reaction–diffusion simulation, three ways:
//
//   1. Sequential   — update the whole grid on one thread.
//   2. Coltrane     — split the grid into row bands, one spawn/join per band.
//   3. async/await  — one child task per band in a TaskGroup.
//
// This is an *iterative stencil*: each of many timesteps is a parallel map over
// the grid (each cell's next value depends on its previous-step neighbours), with
// a barrier between steps. Every cell reads only the previous buffer and writes a
// disjoint output, so the result is deterministic and bit-identical regardless of
// how the rows are split — all three runs are asserted equal, and the final
// concentration field is written as a viewable PGM.
//
// The grid lives in persistent double buffers that the bands write in place (no
// per-step allocation); the holder is `@unchecked Sendable` because the bands
// write disjoint rows. Unlike the other demos this one is *bulk-synchronous* — a
// barrier every step — so it is sensitive to per-barrier latency: Coltrane's
// lock-free spawn path (idle workers re-poll on a ~1 ms interval) trails
// async/await here unless each step is comfortably longer than that, which larger
// grids ensure. It still beats the sequential baseline, and the speedup grows
// with grid size.
//
// Usage: ReactionDiffusionDemo [size] [maxVPs] [steps]   (defaults: 1024, 8, 1000)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

// Gray–Scott parameters (a classic "coral / worms" regime), unit grid, dt = 1.
// Two chemicals U and V react (U + 2V → 3V); `diffU`/`diffV` are their diffusion
// rates, `feed` replenishes U, and `feed + kill` removes V. These particular
// values sit in the regime that grows labyrinthine, coral-like patterns; nudging
// `feed`/`kill` yields spots, stripes, or mitosis instead.
let diffU = 0.16
let diffV = 0.08
let feed = 0.055
let kill = 0.062
let dt = 1.0

/// Two ping-ponged `u`/`v` fields in raw buffers. `@unchecked Sendable`: a step
/// runs many bands that each write a *disjoint* row range of the output buffers,
/// and the buffers are swapped only between steps (single-threaded), so there is
/// no aliasing.
final class Grid: @unchecked Sendable {

    let width: Int
    let height: Int
    let count: Int
    var uCur: UnsafeMutablePointer<Double>
    var vCur: UnsafeMutablePointer<Double>
    var uNext: UnsafeMutablePointer<Double>
    var vNext: UnsafeMutablePointer<Double>

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        count = width * height
        uCur = .allocate(capacity: count)
        vCur = .allocate(capacity: count)
        uNext = .allocate(capacity: count)
        vNext = .allocate(capacity: count)
    }

    deinit {
        uCur.deallocate()
        vCur.deallocate()
        uNext.deallocate()
        vNext.deallocate()
    }

    /// u = 1, v = 0 everywhere, with a seeded square of reactant in the centre.
    func seed() {
        uCur.update(repeating: 1, count: count)
        vCur.update(repeating: 0, count: count)
        let r = max(2, min(width, height) / 12)
        for y in (height / 2 - r)..<(height / 2 + r) {
            for x in (width / 2 - r)..<(width / 2 + r) {
                uCur[y * width + x] = 0.5
                vCur[y * width + x] = 0.25
            }
        }
    }

    func swapBuffers() {
        swap(&uCur, &uNext)
        swap(&vCur, &vNext)
    }

    /// One Gray–Scott step for rows `r0..<r1`, reading `*Cur` and writing `*Next`
    /// (periodic boundaries). Disjoint row ranges run concurrently.
    func step(_ r0: Int, _ r1: Int) {
        let w = width, h = height
        let u = uCur, v = vCur, un = uNext, vn = vNext
        for y in r0..<r1 {
            // Neighbour row offsets, wrapping around the edges (torus topology);
            // the `+ h`/`+ w` before `%` keeps the index non-negative.
            let up = ((y - 1 + h) % h) * w
            let dn = ((y + 1) % h) * w
            let row = y * w
            for x in 0..<w {
                let xL = (x - 1 + w) % w
                let xR = (x + 1) % w
                let cu = u[row + x], cv = v[row + x]
                // Discrete Laplacian: 4-neighbour sum minus 4× the centre.
                let lapU = u[up + x] + u[dn + x] + u[row + xL] + u[row + xR] - 4 * cu
                let lapV = v[up + x] + v[dn + x] + v[row + xL] + v[row + xR] - 4 * cv
                // Gray–Scott update: diffusion ± the U+2V→3V reaction, with feed of
                // U and removal of V, stepped forward by `dt` (explicit Euler).
                let reaction = cu * cv * cv
                un[row + x] = cu + (diffU * lapU - reaction + feed * (1 - cu)) * dt
                vn[row + x] = cv + (diffV * lapV + reaction - (feed + kill) * cv) * dt
            }
        }
    }

    func snapshotV() -> [Double] {
        Array(UnsafeBufferPointer(start: vCur, count: count))
    }
}

func rowBands(_ height: Int, _ count: Int) -> [(Int, Int)] {
    let bands = max(1, min(count, height))
    let size = (height + bands - 1) / bands
    var ranges: [(Int, Int)] = []
    var lo = 0
    while lo < height {
        ranges.append((lo, min(height, lo + size)))
        lo += size
    }
    return ranges
}

// MARK: 1. Sequential

func runSequential(_ grid: Grid, steps: Int) {
    for _ in 0..<steps {
        grid.step(0, grid.height)
        grid.swapBuffers()
    }
}

// MARK: 2. Coltrane spawn/join

func runColtrane(_ grid: Grid, steps: Int, bands: [(Int, Int)]) {
    for _ in 0..<steps {
        let handles = bands.map { band in
            Coltrane.shared.spawn { grid.step(band.0, band.1) }
        }
        for handle in handles {
            handle.join()
        }
        grid.swapBuffers()
    }
}

// MARK: 3. Swift async/await

func runAsync(_ grid: Grid, steps: Int, bands: [(Int, Int)]) async {
    for _ in 0..<steps {
        await withTaskGroup(of: Void.self) { group in
            for band in bands {
                group.addTask { grid.step(band.0, band.1) }
            }
            for await _ in group {}
        }
        grid.swapBuffers()
    }
}

// MARK: Output

/// FNV-1a 64-bit hash over the field's raw bit patterns — a cheap fingerprint to
/// assert the three runs are identical. The constants are the standard FNV offset
/// basis and prime.
func checksum(_ a: [Double]) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for x in a {
        h = (h ^ x.bitPattern) &* 1_099_511_628_211
    }
    return h
}

func writePGM(_ field: [Double], width: Int, height: Int, to path: String) {
    let peak = max(field.max() ?? 1, 1e-9)
    var bytes = [UInt8](repeating: 0, count: width * height)
    for i in field.indices {
        bytes[i] = UInt8(max(0, min(255, 255 * field[i] / peak)))
    }
    var data = Data("P5\n\(width) \(height)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do { try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(width)x\(height))")
    } catch { print("could not write \(path): \(error)") }
}

func asciiPreview(_ field: [Double], width: Int, height: Int, columns: Int = 72) {
    let ramp = Array(" .:-=+*#%@")
    let peak = max(field.max() ?? 1, 1e-9)
    let step = max(1, width / columns)
    var output = ""
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let value = field[y * width + x] / peak
            output.append(ramp[min(ramp.count - 1, Int(value * Double(ramp.count - 1) + 0.5))])
            x += step
        }
        output.append("\n")
        y += step * 2
    }
    print(output, terminator: "")
}

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

func report(_ label: String, _ field: [Double], since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ checksum=%016llx  (%.1f ms)", padded, checksum(field), elapsedMilliseconds(since: start)))
}

// MARK: Driver

let size = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1024) : 1024
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let steps = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 1000) : 1000
let width = size, height = size
let chunks = maxVPs
print("grid \(width)x\(height)  steps=\(steps)  maxVPs=\(maxVPs)  chunks=\(chunks)")

let grid = Grid(width: width, height: height)
let bands = rowBands(height, chunks)

// 1. Sequential
grid.seed()
let seqStart = Date()
runSequential(grid, steps: steps)
let sequential = grid.snapshotV()
report("sequential", sequential, since: seqStart)

// 2. Coltrane spawn/join
grid.seed()
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat per-row fan-out
let coltraneStart = Date()
runColtrane(grid, steps: steps, bands: bands)
let coltrane = grid.snapshotV()
report("coltrane (\(maxVPs) VP)", coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
grid.seed()
let asyncStart = Date()
await runAsync(grid, steps: steps, bands: bands)
let asynchronous = grid.snapshotV()
report("async/await", asynchronous, since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must produce the identical field"
)

print("")
asciiPreview(coltrane, width: width, height: height)
writePGM(coltrane, width: width, height: height, to: "reaction.pgm")
