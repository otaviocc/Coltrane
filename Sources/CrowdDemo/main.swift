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

// CrowdDemo — Helbing's social-force model of a crowd evacuating a room, with
// the pedestrian–pedestrian force computed three ways, for comparison:
//
//   1. Sequential  — one thread over all pedestrians.
//   2. Coltrane    — pedestrians split into chunks, one spawn/join per chunk.
//   3. async/await — one child task per chunk in a TaskGroup.
//
// This is the N-body problem with the sign flipped. In NBodyDemo gravity *pulls*
// bodies together; here the social force *pushes* pedestrians apart — everyone
// wants personal space. The interaction still falls off with distance, so the
// very same Barnes–Hut quadtree works: build a tree of the people, then for each
// person walk the tree, lumping a sufficiently distant cluster into one repeller
// at its centre of mass (the s/d < θ criterion). That turns the O(N²) all-pairs
// social force into O(N log N).
//
// On top of the long-range repulsion are Helbing's short-range *granular* terms
// — body compression and sliding friction — which only fire when bodies actually
// touch. Those reproduce the door-clogging arch and the famous "faster-is-slower"
// effect (raise the desired speed with --v0 and watch the room take *longer* to
// empty). See Helbing, Farkas & Vicsek, "Simulating dynamical features of escape
// panic", Nature 407 (2000).
//
// The parallel structure matches NBodyDemo exactly: building the tree is
// sequential shared work; the force evaluation is per-person independent (each
// person only *reads* the finished tree plus its neighbours' velocities), so it
// parallelizes with no locks. Long-range cells contribute the social term only
// (distant clusters never overlap); the walk bottoms out at single-person leaves,
// where the full social + contact + friction interaction is computed exactly.
// Because every person sums over the tree in the same fixed child order and the
// contact terms only fire at leaves, the result is bit-identical across threads —
// so the three methods are asserted exactly equal, not merely close.
//
// The tree is a flat array of value-type cells traversed through an
// UnsafeBufferPointer, so the hot force loop is free of ARC traffic (see the
// NBodyDemo header for why that matters for scaling).
//
// After the timed comparison the demo runs the evacuation, printing how many
// people have escaped over time and writing a colour PPM of the final state (plus
// an ASCII preview of the room). Pass --save to write a PPM frame sequence into
// ./output for assembly into a video.
//
// Usage: CrowdDemo [n] [maxVPs] [steps] [doorWidth] [doors] [--save] [--stride=K] [--v0=S]
//        (defaults: n=400, maxVPs=8, steps=20000, doorWidth=1.2, doors=1, stride=200, v0=3.0)
//
// With doors > 1 the right wall gets that many evenly spaced openings and each
// pedestrian heads for the one nearest their current position. doors == 1 is the
// original single centred door, unchanged.

import Coltrane
import Foundation

// swiftlint:disable identifier_name file_length

// MARK: Arguments — positional [n] [maxVPs] [steps] plus optional flags

var positional: [String] = []
var saveFrames = false
var frameStride = 200
var v0Override: Double?
for arg in CommandLine.arguments.dropFirst() {
    if arg == "--save" {
        saveFrames = true
    } else if arg.hasPrefix("--stride=") {
        frameStride = max(1, Int(arg.dropFirst("--stride=".count)) ?? 200)
    } else if arg.hasPrefix("--v0=") {
        v0Override = Double(arg.dropFirst("--v0=".count))
    } else {
        positional.append(arg)
    }
}

let n = !positional.isEmpty ? (Int(positional[0]) ?? 400) : 400
let maxVPs = positional.count > 1 ? (Int(positional[1]) ?? 8) : 8
let steps = positional.count > 2 ? (Int(positional[2]) ?? 20000) : 20000
let doorWidth = positional.count > 3 ? (Double(positional[3]) ?? 1.2) : 1.2 // meters
let doors = positional.count > 4 ? max(1, Int(positional[4]) ?? 1) : 1 // openings in the right wall
let chunks = maxVPs * 8

// MARK: Physical constants (Helbing, Farkas & Vicsek, Nature 2000)

let mass = 80.0 // kg, per pedestrian
let radius = 0.3 // m, per pedestrian
let pedDiameter = 2 * radius // rij for two equal pedestrians in contact
let desiredSpeed = v0Override ?? 3.0 // v0: how fast people *want* to move toward the exit
let tau = 0.5 // s, relaxation time of the driving force
let socialA = 2000.0 // N, social repulsion strength
let socialB = 0.08 // m, social repulsion falloff length
let bodyForceK = 1.2e5 // kg/s², body-compression stiffness (contact only)
let frictionK = 2.4e5 // kg/(m·s), sliding-friction coefficient (contact only)
let theta = 0.5 // Barnes–Hut opening angle (smaller = more accurate, slower)
let theta2 = theta * theta // θ² so the opening test compares squares (no sqrt)
let dt = 1.0 / 1000.0 // s, integration time step (small: the contact forces are stiff)

// MARK: Room geometry — a square room with a door gap in the right wall

let placementSpacing = 1.0 // m, initial centre-to-centre spacing of the crowd grid
let roomMargin = 2.0 // m, clear space between the crowd and the walls at t=0
let gridCols = max(1, Int(Double(n).squareRoot().rounded(.up)))
let roomSize = Double(gridCols) * placementSpacing + 2 * roomMargin
// Doors are evenly spaced along the right wall: door i is centred at the middle of
// the i-th of `doors` equal segments. With doors == 1 this is exactly roomSize / 2,
// the original single centred door, so a one-door run is unchanged.
let doorCenters = (0..<doors).map { roomSize * (Double($0) + 0.5) / Double(doors) }
let doorLos = doorCenters.map { $0 - doorWidth / 2 }
let doorHis = doorCenters.map { $0 + doorWidth / 2 }
let exitBuffer = 3.0 // m past the door the desired-direction target sits, so people aim *through* it

/// Whether `y` falls inside any door opening (a gap in the right wall).
@inline(__always)
func inDoorGap(_ y: Double) -> Bool {
    for i in doorLos.indices where y > doorLos[i] && y < doorHis[i] { return true }
    return false
}

/// The opening (lo, hi) of the door nearest `y`. Each pedestrian heads for the door
/// closest to their current position; ties go to the lower door. With a single door
/// this always returns that door.
@inline(__always)
func nearestDoor(_ y: Double) -> (lo: Double, hi: Double) {
    var best = 0
    var bestDist = Double.greatestFiniteMagnitude
    for i in doorCenters.indices {
        let dist = abs(y - doorCenters[i])
        if dist < bestDist {
            bestDist = dist
            best = i
        }
    }
    return (doorLos[best], doorHis[best])
}

struct Vec2: Equatable {

    var x: Double
    var y: Double
}

struct RGB {

    var r: Double
    var g: Double
    var b: Double
}

/// A pedestrian. Mass and radius are uniform (shared constants), so an `Agent`
/// is just kinematic state — which keeps the value type small and the tree
/// weighting (one person = one unit) trivial and deterministic.
struct Agent {

    var x: Double, y: Double // position
    var vx: Double, vy: Double // velocity
}

// MARK: Deterministic RNG (so all runs share identical initial conditions)

struct LCG {

    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0) // [0, 1)
    }
}

/// A jittered grid of pedestrians in the left/interior of the room, each at rest
/// and (via the driving force) wanting to reach the door. Deterministic for `n`.
func makeAgents(_ n: Int) -> [Agent] {
    var rng = LCG(state: 0x9E37_79B9_7F4A_7C15)
    var agents = [Agent]()
    agents.reserveCapacity(n)
    for k in 0..<n {
        let col = k % gridCols
        let row = k / gridCols
        // Jitter < half the gap to neighbours, so nobody starts overlapping.
        let jx = (rng.next() - 0.5) * 0.3 * placementSpacing
        let jy = (rng.next() - 0.5) * 0.3 * placementSpacing
        let x = roomMargin + (Double(col) + 0.5) * placementSpacing + jx
        let y = roomMargin + (Double(row) + 0.5) * placementSpacing + jy
        agents.append(Agent(x: x, y: y, vx: 0, vy: 0))
    }
    return agents
}

// MARK: Barnes–Hut quadtree — flat, value-type cells indexed by Int32

/// One quadtree cell. `mass` here is the pedestrian *count* in the cell (each
/// person weighs 1), `comX/comY` their centre of mass. `bodyIndex >= 0` marks a
/// single-person leaf; `cN` are child cell indices or -1. All scalars (no class
/// references), so a `[BHCell]` is a contiguous buffer readable concurrently
/// with no reference counting.
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
    let agents: [Agent]

    init(cx: Double, cy: Double, half: Double, agents: [Agent]) {
        var root = BHCell()
        root.cx = cx
        root.cy = cy
        root.half = half
        cells = [root]
        self.agents = agents
        cells.reserveCapacity(agents.count * 2)
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

    /// Each person contributes weight 1, so `mass` accumulates a head count.
    func insert(_ idx: Int, _ i: Int, _ px: Double, _ py: Double) {
        if cells[idx].mass == 0, cells[idx].bodyIndex == -1, !cells[idx].hasChildren {
            cells[idx].bodyIndex = Int32(i)
            cells[idx].mass = 1
            cells[idx].comX = px
            cells[idx].comY = py
            return
        }
        if cells[idx].bodyIndex != -1 { // leaf → push existing person down
            let j = Int(cells[idx].bodyIndex)
            cells[idx].bodyIndex = -1
            let cq = ensureChild(idx, quadrant(idx, agents[j].x, agents[j].y))
            insert(cq, j, agents[j].x, agents[j].y)
        }
        let total = cells[idx].mass + 1
        cells[idx].comX = (cells[idx].comX * cells[idx].mass + px) / total
        cells[idx].comY = (cells[idx].comY * cells[idx].mass + py) / total
        cells[idx].mass = total
        let cq = ensureChild(idx, quadrant(idx, px, py))
        insert(cq, i, px, py)
    }
}

func buildCells(_ agents: [Agent]) -> [BHCell] {
    var lo = Vec2(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude)
    var hi = Vec2(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)
    for a in agents {
        lo.x = min(lo.x, a.x)
        lo.y = min(lo.y, a.y)
        hi.x = max(hi.x, a.x)
        hi.y = max(hi.y, a.y)
    }
    let cx = (lo.x + hi.x) / 2, cy = (lo.y + hi.y) / 2
    let half = max(hi.x - lo.x, hi.y - lo.y) / 2 * 1.0001 + 1e-9
    let builder = TreeBuilder(cx: cx, cy: cy, half: half, agents: agents)
    for i in agents.indices {
        builder.insert(0, i, agents[i].x, agents[i].y)
    }
    return builder.cells
}

// MARK: Social force — repulsion (the sign-flipped N-body interaction)

/// Exact pairwise interaction between person `i` and a nearby person `j`: social
/// repulsion, plus — only when they actually overlap — body compression and
/// sliding friction. n̂ points from `j` to `i`, so the repulsion pushes them apart.
@inline(__always)
func pairForce(_ i: Int, _ j: Int, _ agents: UnsafeBufferPointer<Agent>) -> Vec2 {
    let ai = agents[i], aj = agents[j]
    let dx = ai.x - aj.x
    let dy = ai.y - aj.y
    let d = (dx * dx + dy * dy).squareRoot()
    // Deterministic fallback direction if two people exactly coincide.
    let nx = d > 1e-9 ? dx / d : 1.0
    let ny = d > 1e-9 ? dy / d : 0.0

    let diff = pedDiameter - d // > 0 ⇒ overlapping (in contact)
    let social = socialA * exp(diff / socialB)
    let body = diff > 0 ? bodyForceK * diff : 0
    let normalMag = social + body
    var fx = normalMag * nx
    var fy = normalMag * ny

    if diff > 0 {
        // Sliding friction opposes the tangential component of relative velocity.
        let tx = -ny, ty = nx
        let dvt = (aj.vx - ai.vx) * tx + (aj.vy - ai.vy) * ty
        let fric = frictionK * diff * dvt
        fx += fric * tx
        fy += fric * ty
    }
    return Vec2(x: fx, y: fy)
}

/// Total pedestrian–pedestrian force on person `i` from cell `idx`'s subtree.
/// Fixed child order, so the floating-point sum is deterministic across threads.
/// Distant cells (s/d < θ) contribute the social term only — clusters that far
/// away never overlap, so there are no contact terms to add.
func socialForce(
    _ i: Int,
    _ px: Double,
    _ py: Double,
    _ idx: Int,
    _ cells: UnsafeBufferPointer<BHCell>,
    _ agents: UnsafeBufferPointer<Agent>
) -> Vec2 {
    let cell = cells[idx]
    if cell.mass == 0 { return Vec2(x: 0, y: 0) }

    let dx = px - cell.comX // from the cluster toward person i ⇒ repulsion points outward
    let dy = py - cell.comY
    let d2 = dx * dx + dy * dy

    if cell.bodyIndex != -1 {
        if Int(cell.bodyIndex) == i { return Vec2(x: 0, y: 0) } // skip self
        return pairForce(i, Int(cell.bodyIndex), agents)
    }

    let size = 2 * cell.half
    if size * size < theta2 * d2 { // s/d < θ → treat the whole cluster as one repeller
        let d = d2.squareRoot()
        let invD = d > 1e-9 ? 1.0 / d : 0.0
        let social = socialA * cell.mass * exp((pedDiameter - d) / socialB)
        return Vec2(x: social * dx * invD, y: social * dy * invD)
    }

    var fx = 0.0, fy = 0.0
    if cell.c0 != -1 { let f = socialForce(i, px, py, Int(cell.c0), cells, agents)
        fx += f.x
        fy += f.y
    }
    if cell.c1 != -1 { let f = socialForce(i, px, py, Int(cell.c1), cells, agents)
        fx += f.x
        fy += f.y
    }
    if cell.c2 != -1 { let f = socialForce(i, px, py, Int(cell.c2), cells, agents)
        fx += f.x
        fy += f.y
    }
    if cell.c3 != -1 { let f = socialForce(i, px, py, Int(cell.c3), cells, agents)
        fx += f.x
        fy += f.y
    }
    return Vec2(x: fx, y: fy)
}

// MARK: Driving force and walls (each depends only on the person itself)

/// The force pulling a person toward the exit: relax the velocity toward
/// `desiredSpeed` in the direction of a target sitting just outside the door
/// nearest them. The target's y is clamped into that opening, so people funnel
/// toward the gap they are heading for.
@inline(__always)
func drivingForce(_ a: Agent) -> Vec2 {
    let door = nearestDoor(a.y)
    let targetY = min(max(a.y, door.lo + radius), door.hi - radius)
    var ex = (roomSize + exitBuffer) - a.x
    var ey = targetY - a.y
    let len = (ex * ex + ey * ey).squareRoot()
    if len > 1e-9 { ex /= len
        ey /= len
    }
    return Vec2(
        x: mass * (desiredSpeed * ex - a.vx) / tau,
        y: mass * (desiredSpeed * ey - a.vy) / tau
    )
}

/// Repulsion from one wall point, given the perpendicular distance `d` and the
/// inward unit normal (nx, ny). Same social + contact + friction form as a
/// pedestrian, but the wall is static (so friction opposes the person's own
/// tangential velocity).
@inline(__always)
func wallContribution(_ d: Double, _ nx: Double, _ ny: Double, _ vx: Double, _ vy: Double) -> Vec2 {
    let diff = radius - d
    let social = socialA * exp(diff / socialB)
    let body = diff > 0 ? bodyForceK * diff : 0
    let normalMag = social + body
    var fx = normalMag * nx
    var fy = normalMag * ny
    if diff > 0 {
        let tx = -ny, ty = nx
        let vt = vx * tx + vy * ty
        let fric = -frictionK * diff * vt
        fx += fric * tx
        fy += fric * ty
    }
    return Vec2(x: fx, y: fy)
}

/// Repulsion from a single corner point (e.g. a door jamb): the nearest-wall-point
/// interaction with a 0-D obstacle. These two posts at the door edges are what
/// squeeze the crowd into the famous clogging arch.
@inline(__always)
func postContribution(_ postX: Double, _ postY: Double, _ a: Agent) -> Vec2 {
    let dx = a.x - postX
    let dy = a.y - postY
    let d = (dx * dx + dy * dy).squareRoot()
    let nx = d > 1e-9 ? dx / d : 1.0
    let ny = d > 1e-9 ? dy / d : 0.0
    return wallContribution(d, nx, ny, a.vx, a.vy)
}

/// Total wall force: the four room walls (the right wall has a gap at each door)
/// plus a jamb post on either side of every door.
func wallForce(_ a: Agent) -> Vec2 {
    var fx = 0.0, fy = 0.0
    // Left wall (x = 0), inward normal +x.
    var f = wallContribution(a.x, 1, 0, a.vx, a.vy)
    fx += f.x
    fy += f.y
    // Bottom wall (y = 0), inward normal +y.
    f = wallContribution(a.y, 0, 1, a.vx, a.vy)
    fx += f.x
    fy += f.y
    // Top wall (y = roomSize), inward normal −y.
    f = wallContribution(roomSize - a.y, 0, -1, a.vx, a.vy)
    fx += f.x
    fy += f.y
    // Right wall (x = roomSize), inward normal −x — solid except across the doors.
    if !inDoorGap(a.y) {
        f = wallContribution(roomSize - a.x, -1, 0, a.vx, a.vy)
        fx += f.x
        fy += f.y
    }
    // Door jambs — two posts per door, lower edge first so the sum order is fixed.
    for i in doorLos.indices {
        f = postContribution(roomSize, doorLos[i], a)
        fx += f.x
        fy += f.y
        f = postContribution(roomSize, doorHis[i], a)
        fx += f.x
        fy += f.y
    }
    return Vec2(x: fx, y: fy)
}

/// Acceleration on person `i`: (social + driving + walls) / mass. Always summed in
/// this fixed order, so the three force evaluations stay bit-identical.
func totalAcceleration(
    _ i: Int,
    _ cells: UnsafeBufferPointer<BHCell>,
    _ agents: UnsafeBufferPointer<Agent>
) -> Vec2 {
    let a = agents[i]
    let social = socialForce(i, a.x, a.y, 0, cells, agents)
    let drive = drivingForce(a)
    let wall = wallForce(a)
    return Vec2(
        x: (social.x + drive.x + wall.x) / mass,
        y: (social.y + drive.y + wall.y) / mass
    )
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

/// Accelerations for a contiguous person range. Reads both arrays through unsafe
/// buffers so the inner traversal (and the neighbour-velocity lookups) touch no
/// reference counts.
func forcesForRange(_ range: Range<Int>, _ agents: [Agent], _ cells: [BHCell]) -> [Vec2] {
    cells.withUnsafeBufferPointer { cbuf in
        agents.withUnsafeBufferPointer { abuf in
            range.map { i in totalAcceleration(i, cbuf, abuf) }
        }
    }
}

func forcesSequential(_ agents: [Agent], _ cells: [BHCell]) -> [Vec2] {
    forcesForRange(0..<agents.count, agents, cells)
}

func forcesColtrane(_ agents: [Agent], _ cells: [BHCell], chunks: Int) -> [Vec2] {
    let ranges = chunkRanges(agents.count, count: chunks)
    let handles = ranges.map { range in
        Coltrane.shared.spawn { forcesForRange(range, agents, cells) }
    }
    var acc = [Vec2]()
    acc.reserveCapacity(agents.count)
    for handle in handles {
        acc.append(contentsOf: handle.join())
    }
    return acc
}

func forcesAsync(_ agents: [Agent], _ cells: [BHCell], chunks: Int) async -> [Vec2] {
    let ranges = chunkRanges(agents.count, count: chunks)
    return await withTaskGroup(of: (Int, [Vec2]).self) { group in
        for (index, range) in ranges.enumerated() {
            group.addTask { (index, forcesForRange(range, agents, cells)) }
        }
        var parts = [[Vec2]](repeating: [], count: ranges.count)
        for await (index, part) in group {
            parts[index] = part
        }
        return parts.flatMap(\.self)
    }
}

// MARK: Integration

/// Semi-implicit Euler step using the Coltrane force evaluation, then remove
/// anyone who has made it through the door. Returns how many escaped this step.
func step(_ agents: inout [Agent], chunks: Int) -> Int {
    let cells = buildCells(agents)
    let acc = forcesColtrane(agents, cells, chunks: chunks)
    for i in agents.indices {
        agents[i].vx += acc[i].x * dt
        agents[i].vy += acc[i].y * dt
        agents[i].x += agents[i].vx * dt
        agents[i].y += agents[i].vy * dt
    }
    var remaining = [Agent]()
    remaining.reserveCapacity(agents.count)
    var escaped = 0
    for a in agents {
        if a.x > roomSize + radius { escaped += 1 } else { remaining.append(a) }
    }
    agents = remaining
    return escaped
}

// MARK: Rendering

/// Colour image of the room: dark interior, grey walls with the door gap, and
/// each person a filled disk tinted by speed (blue = slow, red = fast).
func renderFrame(_ agents: [Agent], resolution: Int) -> [RGB] {
    let pad = Double(resolution) * 0.04
    let scale = (Double(resolution) - 2 * pad) / roomSize
    var img = [RGB](repeating: RGB(r: 0.04, g: 0.04, b: 0.06), count: resolution * resolution)

    func plot(_ px: Int, _ py: Int, _ c: RGB) {
        if px >= 0, px < resolution, py >= 0, py < resolution { img[py * resolution + px] = c }
    }
    func toPixel(_ wx: Double, _ wy: Double) -> (Int, Int) {
        (Int(pad + wx * scale), Int(Double(resolution) - 1 - (pad + wy * scale)))
    }
    func stamp(_ wx: Double, _ wy: Double, _ c: RGB) {
        let (px, py) = toPixel(wx, wy)
        for ddy in 0...1 {
            for ddx in 0...1 {
                plot(px + ddx, py + ddy, c)
            }
        }
    }

    // Walls, sampled finely enough to be continuous lines on screen.
    let wallColor = RGB(r: 0.55, g: 0.55, b: 0.6)
    let edgeSamples = Int(roomSize * scale) + 1
    for s in 0...edgeSamples {
        let t = Double(s) / Double(edgeSamples) * roomSize
        stamp(t, 0, wallColor) // bottom
        stamp(t, roomSize, wallColor) // top
        stamp(0, t, wallColor) // left
        if !inDoorGap(t) { stamp(roomSize, t, wallColor) } // right (gapped at each door)
    }

    // People.
    let rpx = max(1, Int(radius * scale))
    for a in agents {
        let (cx, cy) = toPixel(a.x, a.y)
        let speed = (a.vx * a.vx + a.vy * a.vy).squareRoot()
        let t = min(1, speed / max(0.1, desiredSpeed))
        let color = RGB(r: 0.2 + 0.8 * t, g: 0.45, b: 1.0 - 0.8 * t)
        for ddy in -rpx...rpx {
            for ddx in -rpx...rpx where ddx * ddx + ddy * ddy <= rpx * rpx {
                plot(cx + ddx, cy + ddy, color)
            }
        }
    }
    return img
}

func toByte(_ value: Double) -> UInt8 {
    UInt8(max(0, min(255, max(0, min(1, value)).squareRoot() * 255)))
}

func writePPM(_ image: [RGB], width: Int, height: Int, to path: String, announce: Bool = true) {
    var bytes = [UInt8]()
    bytes.reserveCapacity(image.count * 3)
    for c in image {
        bytes.append(toByte(c.r))
        bytes.append(toByte(c.g))
        bytes.append(toByte(c.b))
    }
    var data = Data("P6\n\(width) \(height)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do { try data.write(to: URL(fileURLWithPath: path))
        if announce { print("wrote \(path) (\(width)x\(height))") }
    } catch { print("could not write \(path): \(error)") }
}

func saveFrame(_ agents: [Agent], index: Int, dir: String, resolution: Int) {
    writePPM(
        renderFrame(agents, resolution: resolution),
        width: resolution,
        height: resolution,
        to: String(format: "%@/frame_%05d.ppm", dir, index),
        announce: false
    )
}

/// Terminal preview: the room outline with a door gap on the right and a density
/// ramp for the crowd.
func asciiRoom(_ agents: [Agent], columns: Int = 72) {
    let cols = columns
    let rows = max(1, columns / 2)
    var counts = [Int](repeating: 0, count: cols * rows)
    for a in agents {
        let cx = Int(a.x / roomSize * Double(cols))
        let cy = Int(a.y / roomSize * Double(rows))
        if cx >= 0, cx < cols, cy >= 0, cy < rows { counts[(rows - 1 - cy) * cols + cx] += 1 }
    }
    let ramp = Array(".:-=+*#%@")
    let peak = max(1, counts.max() ?? 1)
    print("+" + String(repeating: "-", count: cols) + "+")
    for ry in 0..<rows {
        var line = "|"
        for cx in 0..<cols {
            let c = counts[ry * cols + cx]
            if c == 0 {
                line.append(" ")
            } else {
                let v = Double(c) / Double(peak)
                line.append(ramp[min(ramp.count - 1, Int(v * Double(ramp.count - 1) + 0.5))])
            }
        }
        // World y at this row's centre — open the right wall across each door.
        let wy = (Double(rows - 1 - ry) + 0.5) / Double(rows) * roomSize
        line.append(inDoorGap(wy) ? " " : "|")
        print(line)
    }
    print("+" + String(repeating: "-", count: cols) + "+")
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

print(
    "crowd \(n) people  room \(String(format: "%.0f", roomSize))m  \(doors)×\(doorWidth)m door\(doors == 1 ? "" : "s")  v0=\(desiredSpeed)  Barnes–Hut θ=\(theta)  maxVPs=\(maxVPs)  chunks=\(chunks)"
)

var agents = makeAgents(n)

// Build the tree once (sequential, shared by all three force evaluations).
let treeStart = Date()
let cells = buildCells(agents)
print(String(format: "build tree       %d cells  (%.1f ms)", cells.count, elapsedMilliseconds(since: treeStart)))

// 1. Sequential
let seqStart = Date()
let seq = forcesSequential(agents, cells)
let seqMs = elapsedMilliseconds(since: seqStart)
print(String(format: "sequential       checksum=%016llx  (%.1f ms)", checksum(seq), seqMs))

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat fan-out: help with any pending chunk
let coltraneStart = Date()
let coltrane = forcesColtrane(agents, cells, chunks: chunks)
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
let asynchronous = await forcesAsync(agents, cells, chunks: chunks)
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

// Evacuate (using the Coltrane force evaluation), reporting progress and, if
// --save, snapshotting frames for a video.
let outputDir = "output"
var savedFrames = 0
var totalEscaped = 0
if steps > 0 {
    let saveNote = saveFrames ? ", saving every \(frameStride) step\(frameStride == 1 ? "" : "s") to \(outputDir)/" : ""
    print(
        "\nevacuating \(n) people through \(doors) \(doorWidth)m door\(doors == 1 ? "" : "s") for \(steps) steps (\(String(format: "%.1f", Double(steps) * dt))s)\(saveNote)…"
    )
    if saveFrames {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        saveFrame(agents, index: savedFrames, dir: outputDir, resolution: 700)
        savedFrames += 1
    }
    let reportEvery = max(1, steps / 20)
    for s in 0..<steps {
        totalEscaped += step(&agents, chunks: chunks)
        if saveFrames, (s + 1) % frameStride == 0 {
            saveFrame(agents, index: savedFrames, dir: outputDir, resolution: 700)
            savedFrames += 1
        }
        if agents.isEmpty {
            print(String(format: "  t=%6.2fs  escaped %d/%d  — room empty", Double(s + 1) * dt, totalEscaped, n))
            break
        }
        if (s + 1) % reportEvery == 0 {
            print(String(
                format: "  t=%6.2fs  escaped %d/%d  (in room %d)",
                Double(s + 1) * dt,
                totalEscaped,
                n,
                agents.count
            ))
        }
    }
}

Coltrane.shared.terminate()

print("")
asciiRoom(agents)
writePPM(renderFrame(agents, resolution: 700), width: 700, height: 700, to: "crowd.ppm")

if saveFrames, steps > 0 {
    print("""

    wrote \(savedFrames) frames to \(outputDir)/ — assemble an animation with:
      mp4: ffmpeg -framerate 30 -i \(outputDir)/frame_%05d.ppm -pix_fmt yuv420p crowd.mp4
      gif: ffmpeg -framerate 30 -i \(outputDir)/frame_%05d.ppm crowd.gif
    """)
}

// swiftlint:enable identifier_name file_length
