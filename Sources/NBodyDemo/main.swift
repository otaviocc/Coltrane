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

// NBodyDemo — a gravitational N-body step computed three ways, for comparison:
//
//   1. Sequential  — one thread over all bodies.
//   2. Coltrane    — bodies split into chunks, one spawn/join per chunk.
//   3. async/await — one child task per chunk in a TaskGroup.
//
// Forces use the Barnes–Hut approximation: build a quadtree of the bodies, then
// for each body walk the tree, treating a sufficiently distant cell as a single
// point mass (the s/d < θ criterion). That turns the O(N²) all-pairs force into
// O(N log N).
//
// The parallel structure: building the tree is sequential shared work; the force
// evaluation is per-body independent (each body only *reads* the finished tree),
// so it parallelizes cleanly with no locks. Because every body sums its force
// over the tree in the same fixed order, the result is bit-identical regardless
// of how the bodies are distributed across threads — so the three methods are
// asserted exactly equal, not merely close.
//
// The tree is stored as a flat array of value-type cells (not a graph of class
// nodes) and traversed through an UnsafeBufferPointer. That keeps the hot force
// loop free of ARC retain/release on shared objects — atomic refcount traffic on
// a class-based tree shared across threads would otherwise cap scaling badly (it
// even kept async/await near ~1.4x).
//
// After the timed comparison the demo runs a short simulation and writes the
// final body density to a viewable PGM (plus an ASCII preview).
//
// Usage: NBodyDemo [n] [maxVPs] [steps]   (defaults: 50000, 8, 15)

import Coltrane
import Foundation

// swiftlint:disable identifier_name file_length

struct Vec2: Equatable {

    var x: Double
    var y: Double
}

struct Body {

    var x: Double, y: Double // position
    var vx: Double, vy: Double // velocity
    var mass: Double
}

// Simulation constants.
let G = 1.0 // gravitational constant (units chosen so it's 1)
let theta = 0.5 // Barnes–Hut opening angle: smaller = more accurate, slower
let theta2 = theta * theta // θ² so the opening test can compare squares (no sqrt)
let softening2 = 0.0025 * 0.0025 // ε²: floors the distance so near-collisions don't blow up the force
let dt = 1.0 / 512.0 // integration time step
let diskRadius = 1.0

// MARK: Deterministic RNG (so all runs share identical initial conditions)

struct LCG {

    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0) // [0, 1)
    }
}

/// A rotating disk: a heavy central mass with light bodies on near-circular
/// orbits around it. Deterministic for a given `n`.
func makeBodies(_ n: Int) -> [Body] {
    var rng = LCG(state: 0x9E37_79B9_7F4A_7C15)
    var bodies = [Body]()
    bodies.reserveCapacity(n)

    // A heavy central body (half the total mass) anchors the disk at the origin.
    let centralMass = Double(n) * 0.5
    bodies.append(Body(x: 0, y: 0, vx: 0, vy: 0, mass: centralMass))

    for _ in 1..<n {
        // Random radius in [0.05, 1]·R and angle, placing the body on the disk.
        let r = diskRadius * (0.05 + 0.95 * rng.next())
        let a = 2 * Double.pi * rng.next()
        let x = r * cos(a), y = r * sin(a)
        // Circular-orbit speed √(GM/r), directed tangentially (perpendicular to the
        // radius, hence (−sin, cos)), so the disk rotates rather than collapses.
        let speed = (G * centralMass / r).squareRoot()
        bodies.append(Body(x: x, y: y, vx: -sin(a) * speed, vy: cos(a) * speed, mass: 1.0))
    }
    return bodies
}

// MARK: Barnes–Hut quadtree — flat, value-type cells indexed by Int32

/// One quadtree cell. All scalars (no class references), so a `[BHCell]` is a
/// contiguous buffer that can be read concurrently with no reference counting.
/// `bodyIndex >= 0` marks a single-body leaf; `cN` are child cell indices or -1.
struct BHCell {

    var mass = 0.0
    var comX = 0.0, comY = 0.0
    var cx = 0.0, cy = 0.0, half = 0.0
    var bodyIndex: Int32 = -1
    var c0: Int32 = -1, c1: Int32 = -1, c2: Int32 = -1, c3: Int32 = -1

    var hasChildren: Bool {
        c0 != -1 || c1 != -1 || c2 != -1 || c3 != -1
    }

    func child(_ q: Int) -> Int32 {
        switch q {
        case 0: c0
        case 1: c1
        case 2: c2
        default: c3
        }
    }

    mutating func setChild(_ q: Int, _ value: Int32) {
        switch q {
        case 0: c0 = value
        case 1: c1 = value
        case 2: c2 = value
        default: c3 = value
        }
    }
}

/// Builds the flat cell array. Uses indices (not pointers) so appends that grow
/// — and possibly reallocate — the array never invalidate work in progress.
final class TreeBuilder {

    var cells: [BHCell]
    let bodies: [Body]

    init(cx: Double, cy: Double, half: Double, bodies: [Body]) {
        var root = BHCell()
        root.cx = cx
        root.cy = cy
        root.half = half
        cells = [root]
        self.bodies = bodies
        cells.reserveCapacity(bodies.count * 2)
    }

    /// Quadrant index: one bit per axis (bit 0 = x east of centre, bit 1 = y north).
    private func quadrant(_ idx: Int, _ x: Double, _ y: Double) -> Int {
        (x >= cells[idx].cx ? 1 : 0) | (y >= cells[idx].cy ? 2 : 0)
    }

    private func ensureChild(_ idx: Int, _ q: Int) -> Int {
        let existing = cells[idx].child(q)
        if existing != -1 { return Int(existing) }
        let h = cells[idx].half / 2
        var c = BHCell()
        c.cx = cells[idx].cx + (q & 1 == 1 ? h : -h)
        c.cy = cells[idx].cy + (q & 2 == 2 ? h : -h)
        c.half = h
        cells.append(c)
        let newIdx = cells.count - 1
        cells[idx].setChild(q, Int32(newIdx))
        return newIdx
    }

    func insert(_ idx: Int, _ i: Int, _ px: Double, _ py: Double, _ m: Double) {
        if cells[idx].mass == 0, cells[idx].bodyIndex == -1, !cells[idx].hasChildren {
            cells[idx].bodyIndex = Int32(i)
            cells[idx].mass = m
            cells[idx].comX = px
            cells[idx].comY = py
            return
        }
        if cells[idx].bodyIndex != -1 { // leaf → push existing body down
            let j = Int(cells[idx].bodyIndex)
            cells[idx].bodyIndex = -1
            let cq = ensureChild(idx, quadrant(idx, bodies[j].x, bodies[j].y))
            insert(cq, j, bodies[j].x, bodies[j].y, bodies[j].mass)
        }
        let total = cells[idx].mass + m
        cells[idx].comX = (cells[idx].comX * cells[idx].mass + px * m) / total
        cells[idx].comY = (cells[idx].comY * cells[idx].mass + py * m) / total
        cells[idx].mass = total
        let cq = ensureChild(idx, quadrant(idx, px, py))
        insert(cq, i, px, py, m)
    }
}

func buildCells(_ bodies: [Body]) -> [BHCell] {
    var lo = Vec2(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude)
    var hi = Vec2(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)
    for b in bodies {
        lo.x = min(lo.x, b.x)
        lo.y = min(lo.y, b.y)
        hi.x = max(hi.x, b.x)
        hi.y = max(hi.y, b.y)
    }
    let cx = (lo.x + hi.x) / 2, cy = (lo.y + hi.y) / 2
    let half = max(hi.x - lo.x, hi.y - lo.y) / 2 * 1.0001 + 1e-9
    let builder = TreeBuilder(cx: cx, cy: cy, half: half, bodies: bodies)
    for i in bodies.indices {
        builder.insert(0, i, bodies[i].x, bodies[i].y, bodies[i].mass)
    }
    return builder.cells
}

@inline(__always)
func pointAcceleration(_ dx: Double, _ dy: Double, _ d2: Double, _ mass: Double) -> Vec2 {
    // Newtonian acceleration toward a point mass: a = G·m·r̂ / d². Folding the
    // r̂ = (dx, dy)/d normalisation in gives the G·m/d³ factor below. The
    // softening (d² + ε²) keeps d³ from collapsing toward zero at tiny distances.
    let soft = d2 + softening2
    let inv = G * mass / (soft * soft.squareRoot()) // = G·m / (d² + ε²)^(3/2)
    return Vec2(x: dx * inv, y: dy * inv)
}

/// Acceleration on body `i` from cell `idx`'s subtree. Fixed child order, so the
/// floating-point sum is deterministic across threads. Traverses the flat buffer
/// — no ARC on the hot path.
func acceleration(
    _ i: Int,
    _ px: Double,
    _ py: Double,
    _ idx: Int,
    _ cells: UnsafeBufferPointer<BHCell>
) -> Vec2 {
    let cell = cells[idx]
    if cell.mass == 0 { return Vec2(x: 0, y: 0) }

    let dx = cell.comX - px
    let dy = cell.comY - py
    let d2 = dx * dx + dy * dy

    if cell.bodyIndex != -1 {
        if Int(cell.bodyIndex) == i { return Vec2(x: 0, y: 0) } // skip self
        return pointAcceleration(dx, dy, d2, cell.mass)
    }

    let size = 2 * cell.half
    if size * size < theta2 * d2 { // s/d < θ → treat as one mass
        return pointAcceleration(dx, dy, d2, cell.mass)
    }

    var ax = 0.0, ay = 0.0
    if cell.c0 != -1 { let a = acceleration(i, px, py, Int(cell.c0), cells)
        ax += a.x
        ay += a.y
    }
    if cell.c1 != -1 { let a = acceleration(i, px, py, Int(cell.c1), cells)
        ax += a.x
        ay += a.y
    }
    if cell.c2 != -1 { let a = acceleration(i, px, py, Int(cell.c2), cells)
        ax += a.x
        ay += a.y
    }
    if cell.c3 != -1 { let a = acceleration(i, px, py, Int(cell.c3), cells)
        ax += a.x
        ay += a.y
    }
    return Vec2(x: ax, y: ay)
}

// MARK: Force evaluation — three ways

func chunkRanges(_ n: Int, count: Int) -> [Range<Int>] {
    let c = max(1, min(count, n))
    let size = (n + c - 1) / c
    var ranges: [Range<Int>] = []
    var lo = 0
    while lo < n {
        ranges.append(lo..<min(n, lo + size))
        lo += size
    }
    return ranges
}

/// Compute accelerations for a contiguous body range. Reads both arrays through
/// unsafe buffers so the inner traversal touches no reference counts.
func forcesForRange(_ range: Range<Int>, _ bodies: [Body], _ cells: [BHCell]) -> [Vec2] {
    cells.withUnsafeBufferPointer { cbuf in
        bodies.withUnsafeBufferPointer { bbuf in
            range.map { i in acceleration(i, bbuf[i].x, bbuf[i].y, 0, cbuf) }
        }
    }
}

func forcesSequential(_ bodies: [Body], _ cells: [BHCell]) -> [Vec2] {
    forcesForRange(0..<bodies.count, bodies, cells)
}

func forcesColtrane(_ bodies: [Body], _ cells: [BHCell], chunks: Int) -> [Vec2] {
    let ranges = chunkRanges(bodies.count, count: chunks)
    let handles = ranges.map { range in
        Coltrane.shared.spawn { forcesForRange(range, bodies, cells) }
    }
    var acc = [Vec2]()
    acc.reserveCapacity(bodies.count)
    for handle in handles {
        acc.append(contentsOf: handle.join())
    }
    return acc
}

func forcesAsync(_ bodies: [Body], _ cells: [BHCell], chunks: Int) async -> [Vec2] {
    let ranges = chunkRanges(bodies.count, count: chunks)
    return await withTaskGroup(of: (Int, [Vec2]).self) { group in
        for (index, range) in ranges.enumerated() {
            group.addTask { (index, forcesForRange(range, bodies, cells)) }
        }
        var parts = [[Vec2]](repeating: [], count: ranges.count)
        for await (index, part) in group {
            parts[index] = part
        }
        return parts.flatMap(\.self)
    }
}

// MARK: Integration & rendering

/// Semi-implicit Euler step using the Coltrane force evaluation.
func step(_ bodies: inout [Body], chunks: Int) {
    let cells = buildCells(bodies)
    let acc = forcesColtrane(bodies, cells, chunks: chunks)
    for i in bodies.indices {
        bodies[i].vx += acc[i].x * dt
        bodies[i].vy += acc[i].y * dt
        bodies[i].x += bodies[i].vx * dt
        bodies[i].y += bodies[i].vy * dt
    }
}

func density(_ bodies: [Body], resolution: Int, view: Double) -> [Int] {
    var grid = [Int](repeating: 0, count: resolution * resolution)
    let scale = Double(resolution) / (2 * view)
    for b in bodies {
        let px = Int((b.x + view) * scale)
        let py = Int((b.y + view) * scale)
        if px >= 0, px < resolution, py >= 0, py < resolution {
            grid[(resolution - 1 - py) * resolution + px] += 1
        }
    }
    return grid
}

func writePGM(_ grid: [Int], resolution: Int, to path: String) {
    let peak = max(1, grid.max() ?? 1)
    let logPeak = log(Double(peak) + 1)
    var bytes = [UInt8](repeating: 0, count: grid.count)
    for i in grid.indices {
        let v = log(Double(grid[i]) + 1) / logPeak
        bytes[i] = UInt8(max(0, min(255, 255 * v)))
    }
    var data = Data("P5\n\(resolution) \(resolution)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do { try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(resolution)x\(resolution))")
    } catch { print("could not write \(path): \(error)") }
}

func asciiPreview(_ grid: [Int], resolution: Int, columns: Int = 72) {
    let ramp = Array(" .:-=+*#%@")
    let peak = max(1, grid.max() ?? 1)
    let logPeak = log(Double(peak) + 1)
    let step = max(1, resolution / columns)
    var output = ""
    var y = 0
    while y < resolution {
        var x = 0
        while x < resolution {
            var m = 0
            var yy = y
            while yy < min(resolution, y + step * 2) {
                var xx = x
                while xx < min(resolution, x + step) {
                    m = max(m, grid[yy * resolution + xx])
                    xx += 1
                }
                yy += 1
            }
            let v = log(Double(m) + 1) / logPeak
            output.append(ramp[min(ramp.count - 1, Int(v * Double(ramp.count - 1) + 0.5))])
            x += step
        }
        output.append("\n")
        y += step * 2
    }
    print(output, terminator: "")
}

func checksum(_ acc: [Vec2]) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for v in acc {
        h = (h ^ v.x.bitPattern) &* 1_099_511_628_211
        h = (h ^ v.y.bitPattern) &* 1_099_511_628_211
    }
    return h
}

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

// MARK: Driver

let n = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 50000) : 50000
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let steps = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 15) : 15
let chunks = maxVPs * 8
print("n-body \(n) bodies  Barnes–Hut θ=\(theta)  maxVPs=\(maxVPs)  chunks=\(chunks)")

var bodies = makeBodies(n)

// Build the tree once (sequential, shared by all three force evaluations).
let treeStart = Date()
let cells = buildCells(bodies)
print(String(format: "build tree       %d cells  (%.1f ms)", cells.count, elapsedMilliseconds(since: treeStart)))

// 1. Sequential
let seqStart = Date()
let seq = forcesSequential(bodies, cells)
let seqMs = elapsedMilliseconds(since: seqStart)
print(String(format: "sequential       checksum=%016llx  (%.1f ms)", checksum(seq), seqMs))

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat fan-out: help with any pending chunk
let coltraneStart = Date()
let coltrane = forcesColtrane(bodies, cells, chunks: chunks)
let coltraneMs = elapsedMilliseconds(since: coltraneStart)
print(String(
    format: "coltrane (%d VP)  checksum=%016llx  (%.1f ms, %.2fx)",
    maxVPs,
    checksum(coltrane),
    coltraneMs,
    seqMs / coltraneMs
))

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await forcesAsync(bodies, cells, chunks: chunks)
let asyncMs = elapsedMilliseconds(since: asyncStart)
print(String(
    format: "async/await      checksum=%016llx  (%.1f ms, %.2fx)",
    checksum(asynchronous),
    asyncMs,
    seqMs / asyncMs
))

precondition(
    seq == coltrane && coltrane == asynchronous,
    "all three force evaluations must be bit-identical"
)

// Simulate a few steps (using the Coltrane force evaluation) and render.
if steps > 0 {
    print("\nsimulating \(steps) steps…")
    for _ in 0..<steps {
        step(&bodies, chunks: chunks)
    }
}

Coltrane.shared.terminate()

let grid = density(bodies, resolution: 600, view: diskRadius * 1.3)
print("")
asciiPreview(grid, resolution: 600)
writePGM(grid, resolution: 600, to: "nbody.pgm")
