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

// NBody3DDemo — the 3D sibling of NBodyDemo. A gravitational N-body step in
// three dimensions, computed three ways for comparison:
//
//   1. Sequential  — one thread over all bodies.
//   2. Coltrane    — bodies split into chunks, one spawn/join per chunk.
//   3. async/await — one child task per chunk in a TaskGroup.
//
// The scene is two filled, rotating star clusters on a grazing collision course
// (offset by an impact parameter, internal spins aligned with the orbit). They
// merge into a rotating, flattened remnant with tidal tails — a galaxy-like result.
//
// Forces use the Barnes–Hut approximation, but here over an *octree* (eight
// children per cell — the cube split along x, y, and z) instead of the 2D
// quadtree. For each body we walk the tree, treating a sufficiently distant cell
// as a single point mass (the s/d < θ criterion). That turns the O(N²) all-pairs
// force into O(N log N).
//
// The parallel structure is identical to the 2D demo: building the tree is
// sequential shared work; the force evaluation is per-body independent (each body
// only *reads* the finished tree), so it parallelizes with no locks. Every body
// sums its force over the tree in the same fixed child order, so the result is
// bit-identical regardless of how bodies are distributed across threads — the
// three methods are asserted exactly equal, not merely close.
//
// The tree is a flat array of value-type cells (not a graph of class nodes),
// traversed through an UnsafeBufferPointer, so the hot force loop carries no ARC
// retain/release traffic on shared objects.
//
// It renders two views: a top-down xy projection and a tilted, depth-shaded 3D
// view. Pass --save to write a PGM frame of each view (every step, or every Kth
// with --stride=K) into ./output/top and ./output/tilted as zero-padded
// sequences (frame_00000.pgm, frame_00001.pgm, …). Assemble one afterwards, e.g.:
//
//   mp4:  ffmpeg -framerate 30 -i output/tilted/frame_%05d.pgm -pix_fmt yuv420p nbody3d_tilted.mp4
//   gif:  ffmpeg -framerate 30 -i output/tilted/frame_%05d.pgm nbody3d_tilted.gif
//
// Usage: NBody3DDemo [n] [maxVPs] [steps] [--save] [--stride=K]   (defaults: 50000, 8, 15)

import Coltrane
import Foundation

// swiftlint:disable identifier_name file_length

struct Vec3: Equatable {

    var x: Double
    var y: Double
    var z: Double

    static let zero = Vec3(x: 0, y: 0, z: 0)
}

struct Body {

    var x: Double, y: Double, z: Double // position
    var vx: Double, vy: Double, vz: Double // velocity
    var mass: Double
}

// Simulation constants.
let G = 1.0
let theta = 0.5
let theta2 = theta * theta
let softening2 = 0.04 * 0.04 // ε ≈ 0.04: collisionless/smooth, suppresses two-body graininess
let dt = 1.0 / 256.0
let diskRadius = 1.0 // radius of each cluster

// Two clusters collide on a grazing trajectory and merge into a rotating remnant.
// Masses are fixed (independent of particle count), so the dynamics don't change
// when N changes — N only controls smoothness/resolution.
let clusterMass = 1.0 // total mass of each cluster; per-particle mass = clusterMass / count
let sphereSeparation = 3 * (2 * diskRadius) // initial center-to-center distance, along x
let impactParameter = 1.6 // perpendicular (y) offset between the two trajectories → orbital spin
let approachSpeed = 0.35 // each cluster's bulk speed toward the other (sub-parabolic → they bind & merge)
let spinFraction = 0.4 // each cluster's internal rotation, as a fraction of circular support
let dispersionFraction = 0.4 // random velocity spread, as a fraction of the edge circular speed

// Tilted-camera view: the world is rotated about the vertical axis (azimuth)
// then tipped toward the camera (elevation) before projecting, so the structure
// reads as 3D rather than as a flat disk.
let cameraAzimuth = 0.6 // radians
let cameraElevation = 0.5 // radians

// MARK: Deterministic RNG (so all runs share identical initial conditions)

struct LCG {

    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0) // [0, 1)
    }
}

/// Appends a filled, rotating cluster of `count` equal-mass particles centered at
/// `center`, moving as a whole at `bulk`.
///
/// Particles uniformly fill a sphere of radius `diskRadius` (`clusterMass` total,
/// so each is `clusterMass / count`). For a uniform sphere the circular speed is
/// `∝ r`, i.e. solid-body rotation, so each particle gets `ω × r` about +z at
/// `spinFraction` of full rotational support, plus an isotropic random dispersion
/// at `dispersionFraction` of the edge circular speed. Together that's roughly
/// virialized, so the cluster holds together instead of collapsing or flying
/// apart. Advances `rng`, so the result is deterministic.
func appendCluster(into bodies: inout [Body], center: Vec3, bulk: Vec3, count: Int, rng: inout LCG) {
    guard count > 0 else { return }
    let r0 = diskRadius
    let mass = clusterMass / Double(count)
    let vCirc = (G * clusterMass / r0).squareRoot() // edge circular speed
    let omega = spinFraction * (G * clusterMass / (r0 * r0 * r0)).squareRoot() // solid-body rate
    let disp = dispersionFraction * vCirc * 3.0.squareRoot() // uniform[-disp,disp] has variance σ²

    for _ in 0..<count {
        // Uniform point inside the sphere: a direction on the unit sphere, with
        // radius ∝ cbrt(u) so density is constant.
        let cosTheta = 2 * rng.next() - 1
        let phi = 2 * Double.pi * rng.next()
        let rad = r0 * cbrt(rng.next())
        let s = (1 - cosTheta * cosTheta).squareRoot()
        let dx = rad * s * cos(phi), dy = rad * s * sin(phi), dz = rad * cosTheta

        // Solid-body rotation about +z (ω × r) plus isotropic random dispersion.
        let vx = -omega * dy + disp * (2 * rng.next() - 1)
        let vy = omega * dx + disp * (2 * rng.next() - 1)
        let vz = disp * (2 * rng.next() - 1)

        bodies.append(Body(
            x: center.x + dx, y: center.y + dy, z: center.z + dz,
            vx: bulk.x + vx, vy: bulk.y + vy, vz: bulk.z + vz,
            mass: mass
        ))
    }
}

/// Two filled, rotating clusters on a grazing collision course: centers
/// `sphereSeparation` apart along x and offset by `impactParameter` in y, each
/// drifting toward the other at `approachSpeed`. The y-offset gives the encounter
/// +z orbital angular momentum, matching both clusters' +z spin (spin–orbit
/// aligned), so they merge into a coherently rotating remnant. Deterministic for
/// a given `n`.
func makeBodies(_ n: Int) -> [Body] {
    var rng = LCG(state: 0x9E37_79B9_7F4A_7C15)
    var bodies = [Body]()
    bodies.reserveCapacity(n)

    let dHalf = sphereSeparation / 2
    let bHalf = impactParameter / 2
    let countA = n / 2
    appendCluster(
        into: &bodies,
        center: Vec3(x: -dHalf, y: -bHalf, z: 0),
        bulk: Vec3(x: approachSpeed, y: 0, z: 0),
        count: countA,
        rng: &rng
    )
    appendCluster(
        into: &bodies,
        center: Vec3(x: dHalf, y: bHalf, z: 0),
        bulk: Vec3(x: -approachSpeed, y: 0, z: 0),
        count: n - countA,
        rng: &rng
    )
    return bodies
}

// MARK: Barnes–Hut octree — flat, value-type cells indexed by Int32

/// One octree cell. All scalars (no class references), so a `[BHCell]` is a
/// contiguous buffer that can be read concurrently with no reference counting.
/// `bodyIndex >= 0` marks a single-body leaf; `cN` are child cell indices or -1.
/// The eight children are indexed by an octant: bit 0 = +x, bit 1 = +y, bit 2 = +z.
struct BHCell {

    var mass = 0.0
    var comX = 0.0, comY = 0.0, comZ = 0.0
    var cx = 0.0, cy = 0.0, cz = 0.0, half = 0.0
    var bodyIndex: Int32 = -1
    var c0: Int32 = -1, c1: Int32 = -1, c2: Int32 = -1, c3: Int32 = -1
    var c4: Int32 = -1, c5: Int32 = -1, c6: Int32 = -1, c7: Int32 = -1

    var hasChildren: Bool {
        c0 != -1 || c1 != -1 || c2 != -1 || c3 != -1
            || c4 != -1 || c5 != -1 || c6 != -1 || c7 != -1
    }

    func child(_ q: Int) -> Int32 {
        switch q {
        case 0: c0
        case 1: c1
        case 2: c2
        case 3: c3
        case 4: c4
        case 5: c5
        case 6: c6
        default: c7
        }
    }

    mutating func setChild(_ q: Int, _ value: Int32) {
        switch q {
        case 0: c0 = value
        case 1: c1 = value
        case 2: c2 = value
        case 3: c3 = value
        case 4: c4 = value
        case 5: c5 = value
        case 6: c6 = value
        default: c7 = value
        }
    }
}

/// Builds the flat cell array. Uses indices (not pointers) so appends that grow
/// — and possibly reallocate — the array never invalidate work in progress.
final class TreeBuilder {

    var cells: [BHCell]
    let bodies: [Body]

    init(cx: Double, cy: Double, cz: Double, half: Double, bodies: [Body]) {
        var root = BHCell()
        root.cx = cx
        root.cy = cy
        root.cz = cz
        root.half = half
        cells = [root]
        self.bodies = bodies
        cells.reserveCapacity(bodies.count * 2)
    }

    private func octant(_ idx: Int, _ x: Double, _ y: Double, _ z: Double) -> Int {
        (x >= cells[idx].cx ? 1 : 0)
            | (y >= cells[idx].cy ? 2 : 0)
            | (z >= cells[idx].cz ? 4 : 0)
    }

    private func ensureChild(_ idx: Int, _ q: Int) -> Int {
        let existing = cells[idx].child(q)
        if existing != -1 { return Int(existing) }
        let h = cells[idx].half / 2
        var c = BHCell()
        c.cx = cells[idx].cx + (q & 1 == 1 ? h : -h)
        c.cy = cells[idx].cy + (q & 2 == 2 ? h : -h)
        c.cz = cells[idx].cz + (q & 4 == 4 ? h : -h)
        c.half = h
        cells.append(c)
        let newIdx = cells.count - 1
        cells[idx].setChild(q, Int32(newIdx))
        return newIdx
    }

    func insert(_ idx: Int, _ i: Int, _ px: Double, _ py: Double, _ pz: Double, _ m: Double) {
        if cells[idx].mass == 0, cells[idx].bodyIndex == -1, !cells[idx].hasChildren {
            cells[idx].bodyIndex = Int32(i)
            cells[idx].mass = m
            cells[idx].comX = px
            cells[idx].comY = py
            cells[idx].comZ = pz
            return
        }
        if cells[idx].bodyIndex != -1 { // leaf → push existing body down
            let j = Int(cells[idx].bodyIndex)
            cells[idx].bodyIndex = -1
            let cq = ensureChild(idx, octant(idx, bodies[j].x, bodies[j].y, bodies[j].z))
            insert(cq, j, bodies[j].x, bodies[j].y, bodies[j].z, bodies[j].mass)
        }
        let total = cells[idx].mass + m
        cells[idx].comX = (cells[idx].comX * cells[idx].mass + px * m) / total
        cells[idx].comY = (cells[idx].comY * cells[idx].mass + py * m) / total
        cells[idx].comZ = (cells[idx].comZ * cells[idx].mass + pz * m) / total
        cells[idx].mass = total
        let cq = ensureChild(idx, octant(idx, px, py, pz))
        insert(cq, i, px, py, pz, m)
    }
}

func buildCells(_ bodies: [Body]) -> [BHCell] {
    var lo = Vec3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude)
    var hi = Vec3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, z: -.greatestFiniteMagnitude)
    for b in bodies {
        lo.x = min(lo.x, b.x)
        lo.y = min(lo.y, b.y)
        lo.z = min(lo.z, b.z)
        hi.x = max(hi.x, b.x)
        hi.y = max(hi.y, b.y)
        hi.z = max(hi.z, b.z)
    }
    let cx = (lo.x + hi.x) / 2, cy = (lo.y + hi.y) / 2, cz = (lo.z + hi.z) / 2
    let half = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z)) / 2 * 1.0001 + 1e-9
    let builder = TreeBuilder(cx: cx, cy: cy, cz: cz, half: half, bodies: bodies)
    for i in bodies.indices {
        builder.insert(0, i, bodies[i].x, bodies[i].y, bodies[i].z, bodies[i].mass)
    }
    return builder.cells
}

@inline(__always)
func pointAcceleration(_ dx: Double, _ dy: Double, _ dz: Double, _ d2: Double, _ mass: Double) -> Vec3 {
    let soft = d2 + softening2
    let inv = G * mass / (soft * soft.squareRoot()) // G·m / d³
    return Vec3(x: dx * inv, y: dy * inv, z: dz * inv)
}

/// Acceleration on body `i` from cell `idx`'s subtree. Fixed child order (0…7),
/// so the floating-point sum is deterministic across threads. Traverses the flat
/// buffer — no ARC on the hot path.
func acceleration(
    _ i: Int,
    _ px: Double,
    _ py: Double,
    _ pz: Double,
    _ idx: Int,
    _ cells: UnsafeBufferPointer<BHCell>
) -> Vec3 {
    let cell = cells[idx]
    if cell.mass == 0 { return .zero }

    let dx = cell.comX - px
    let dy = cell.comY - py
    let dz = cell.comZ - pz
    let d2 = dx * dx + dy * dy + dz * dz

    if cell.bodyIndex != -1 {
        if Int(cell.bodyIndex) == i { return .zero } // skip self
        return pointAcceleration(dx, dy, dz, d2, cell.mass)
    }

    let size = 2 * cell.half
    if size * size < theta2 * d2 { // s/d < θ → treat as one mass
        return pointAcceleration(dx, dy, dz, d2, cell.mass)
    }

    var ax = 0.0, ay = 0.0, az = 0.0
    for q in 0..<8 {
        let c = cell.child(q)
        if c != -1 {
            let a = acceleration(i, px, py, pz, Int(c), cells)
            ax += a.x
            ay += a.y
            az += a.z
        }
    }
    return Vec3(x: ax, y: ay, z: az)
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
func forcesForRange(_ range: Range<Int>, _ bodies: [Body], _ cells: [BHCell]) -> [Vec3] {
    cells.withUnsafeBufferPointer { cbuf in
        bodies.withUnsafeBufferPointer { bbuf in
            range.map { i in acceleration(i, bbuf[i].x, bbuf[i].y, bbuf[i].z, 0, cbuf) }
        }
    }
}

func forcesSequential(_ bodies: [Body], _ cells: [BHCell]) -> [Vec3] {
    forcesForRange(0..<bodies.count, bodies, cells)
}

func forcesColtrane(_ bodies: [Body], _ cells: [BHCell], chunks: Int) -> [Vec3] {
    let ranges = chunkRanges(bodies.count, count: chunks)
    let handles = ranges.map { range in
        Coltrane.shared.spawn { forcesForRange(range, bodies, cells) }
    }
    var acc = [Vec3]()
    acc.reserveCapacity(bodies.count)
    for handle in handles {
        acc.append(contentsOf: handle.join())
    }
    return acc
}

func forcesAsync(_ bodies: [Body], _ cells: [BHCell], chunks: Int) async -> [Vec3] {
    let ranges = chunkRanges(bodies.count, count: chunks)
    return await withTaskGroup(of: (Int, [Vec3]).self) { group in
        for (index, range) in ranges.enumerated() {
            group.addTask { (index, forcesForRange(range, bodies, cells)) }
        }
        var parts = [[Vec3]](repeating: [], count: ranges.count)
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
        bodies[i].vz += acc[i].z * dt
        bodies[i].x += bodies[i].vx * dt
        bodies[i].y += bodies[i].vy * dt
        bodies[i].z += bodies[i].vz * dt
    }
}

/// Projects the bodies onto the xy-plane (dropping z) and bins them into a
/// square density grid — a top-down view, one unit of weight per body.
func density(_ bodies: [Body], resolution: Int, view: Double) -> [Double] {
    var grid = [Double](repeating: 0, count: resolution * resolution)
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

/// Projects through the tilted camera and bins into a density grid, weighting
/// each body by how near it is to the camera so the near side reads brighter
/// than the far side — a depth cue that makes the 3D structure legible.
func densityTilted(_ bodies: [Body], resolution: Int, view: Double) -> [Double] {
    var grid = [Double](repeating: 0, count: resolution * resolution)
    let scale = Double(resolution) / (2 * view)
    let ca = cos(cameraAzimuth), sa = sin(cameraAzimuth)
    let ce = cos(cameraElevation), se = sin(cameraElevation)
    for b in bodies {
        let x1 = b.x * ca - b.y * sa // rotate about vertical (z) axis
        let y1 = b.x * sa + b.y * ca
        let sx = x1 // then tip toward the camera about the screen-x axis
        let sy = y1 * ce - b.z * se
        let depth = y1 * se + b.z * ce // + = nearer the camera
        let px = Int((sx + view) * scale)
        let py = Int((sy + view) * scale)
        if px >= 0, px < resolution, py >= 0, py < resolution {
            let nearness = max(0, min(1, 0.5 + 0.5 * depth / view))
            grid[(resolution - 1 - py) * resolution + px] += 0.25 + 0.75 * nearness
        }
    }
    return grid
}

func writePGM(_ grid: [Double], resolution: Int, to path: String, announce: Bool = true) {
    let peak = max(1e-9, grid.max() ?? 1)
    let logPeak = log(peak + 1)
    var bytes = [UInt8](repeating: 0, count: grid.count)
    for i in grid.indices {
        let v = log(grid[i] + 1) / logPeak
        bytes[i] = UInt8(max(0, min(255, 255 * v)))
    }
    var data = Data("P5\n\(resolution) \(resolution)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do { try data.write(to: URL(fileURLWithPath: path))
        if announce { print("wrote \(path) (\(resolution)x\(resolution))") }
    } catch { print("could not write \(path): \(error)") }
}

/// Renders one simulation frame of each view into `topDir`/`tiltedDir` as
/// `frame_NNNNN.pgm`, for later assembly into a video. Consistent resolution and
/// view across frames so the animation is stable.
func saveFrame(_ bodies: [Body], index: Int, topDir: String, tiltedDir: String, resolution: Int, view: Double) {
    writePGM(
        density(bodies, resolution: resolution, view: view),
        resolution: resolution,
        to: String(format: "%@/frame_%05d.pgm", topDir, index),
        announce: false
    )
    writePGM(
        densityTilted(bodies, resolution: resolution, view: view),
        resolution: resolution,
        to: String(format: "%@/frame_%05d.pgm", tiltedDir, index),
        announce: false
    )
}

func asciiPreview(_ grid: [Double], resolution: Int, columns: Int = 72) {
    let ramp = Array(" .:-=+*#%@")
    let peak = max(1e-9, grid.max() ?? 1)
    let logPeak = log(peak + 1)
    let step = max(1, resolution / columns)
    var output = ""
    var y = 0
    while y < resolution {
        var x = 0
        while x < resolution {
            var m = 0.0
            var yy = y
            while yy < min(resolution, y + step * 2) {
                var xx = x
                while xx < min(resolution, x + step) {
                    m = max(m, grid[yy * resolution + xx])
                    xx += 1
                }
                yy += 1
            }
            let v = log(m + 1) / logPeak
            output.append(ramp[min(ramp.count - 1, Int(v * Double(ramp.count - 1) + 0.5))])
            x += step
        }
        output.append("\n")
        y += step * 2
    }
    print(output, terminator: "")
}

func checksum(_ acc: [Vec3]) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for v in acc {
        h = (h ^ v.x.bitPattern) &* 1_099_511_628_211
        h = (h ^ v.y.bitPattern) &* 1_099_511_628_211
        h = (h ^ v.z.bitPattern) &* 1_099_511_628_211
    }
    return h
}

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

// MARK: Driver

// Arguments: positional [n] [maxVPs] [steps], plus optional flags --save and
// --stride=K (save every Kth step; default 1), which may appear anywhere.
var positional: [String] = []
var save = false
var frameStride = 1
for arg in CommandLine.arguments.dropFirst() {
    if arg == "--save" {
        save = true
    } else if arg.hasPrefix("--stride=") {
        frameStride = max(1, Int(arg.dropFirst("--stride=".count)) ?? 1)
    } else {
        positional.append(arg)
    }
}

let n = !positional.isEmpty ? (Int(positional[0]) ?? 50000) : 50000
let maxVPs = positional.count > 1 ? (Int(positional[1]) ?? 8) : 8
let steps = positional.count > 2 ? (Int(positional[2]) ?? 15) : 15
let chunks = maxVPs * 8
let frameResolution = 600
// Wide enough to frame both clusters (centers ±separation/2, radius diskRadius)
// with margin through the encounter and merger.
let frameView = sphereSeparation / 2 + diskRadius * 5
let outputDir = "output"
let topDir = "\(outputDir)/top"
let tiltedDir = "\(outputDir)/tilted"
print("n-body 3D \(n) bodies  Barnes–Hut octree θ=\(theta)  maxVPs=\(maxVPs)  chunks=\(chunks)")

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

var savedFrames = 0

// Simulate (using the Coltrane force evaluation) and, if --save, snapshot every
// frameStride-th step to ./output as a PGM sequence.
if steps > 0 {
    let saveNote = save ? ", saving every \(frameStride) step\(frameStride == 1 ? "" : "s") to \(outputDir)/" : ""
    print("\nsimulating \(steps) steps\(saveNote)…")
    if save {
        try? FileManager.default.createDirectory(atPath: topDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tiltedDir, withIntermediateDirectories: true)
        saveFrame(
            bodies,
            index: savedFrames,
            topDir: topDir,
            tiltedDir: tiltedDir,
            resolution: frameResolution,
            view: frameView
        )
        savedFrames += 1
    }
    for s in 0..<steps {
        step(&bodies, chunks: chunks)
        if save, (s + 1) % frameStride == 0 {
            saveFrame(
                bodies,
                index: savedFrames,
                topDir: topDir,
                tiltedDir: tiltedDir,
                resolution: frameResolution,
                view: frameView
            )
            savedFrames += 1
        }
    }
}

Coltrane.shared.terminate()

let topGrid = density(bodies, resolution: frameResolution, view: frameView)
let tiltedGrid = densityTilted(bodies, resolution: frameResolution, view: frameView)
print("\ntilted 3D view:")
asciiPreview(tiltedGrid, resolution: frameResolution)
writePGM(topGrid, resolution: frameResolution, to: "nbody3d.pgm")
writePGM(tiltedGrid, resolution: frameResolution, to: "nbody3d_tilted.pgm")

if save, steps > 0 {
    print("""

    wrote \(savedFrames) frames each to \(topDir)/ and \(tiltedDir)/ — assemble an animation with:
      top-down mp4:  ffmpeg -framerate 30 -i \(topDir)/frame_%05d.pgm -pix_fmt yuv420p nbody3d_top.mp4
      tilted 3D mp4: ffmpeg -framerate 30 -i \(tiltedDir)/frame_%05d.pgm -pix_fmt yuv420p nbody3d_tilted.mp4
      (swap -pix_fmt … nbody3d.mp4 for a .gif target to get an animated GIF)
    """)
}
