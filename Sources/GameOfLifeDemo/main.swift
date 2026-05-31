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

// GameOfLifeDemo — Conway's Game of Life, three ways:
//
//   1. Sequential   — advance the whole board on one thread.
//   2. Coltrane     — split the board into row bands, one spawn/join per band.
//   3. async/await  — one child task per band in a TaskGroup.
//
// Like ReactionDiffusionDemo this is a *bulk-synchronous* iterative stencil — a
// barrier every generation, each cell a function of its eight previous-step
// neighbours — so the board is deterministic and bit-identical regardless of how
// the rows are split (all three asserted equal). The cells are very cheap
// (an 8-neighbour count), so each generation is short and the per-barrier latency
// of Coltrane's lock-free spawn shows: it needs a large board to beat sequential,
// and trails async/await. The final board is written as a PGM.
//
// Usage: GameOfLifeDemo [size] [maxVPs] [steps]   (defaults: 2048, 8, 300)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

func splitmix64(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// The board in two ping-ponged buffers. `@unchecked Sendable`: each generation
/// runs bands that write disjoint row ranges of the output buffer, and buffers
/// are swapped only between generations (single-threaded), so there is no aliasing.
final class Board: @unchecked Sendable {

    let width: Int
    let height: Int
    let count: Int
    var cur: UnsafeMutablePointer<UInt8>
    var next: UnsafeMutablePointer<UInt8>

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        count = width * height
        cur = .allocate(capacity: count)
        next = .allocate(capacity: count)
    }

    deinit { cur.deallocate()
        next.deallocate()
    }

    /// Deterministic random soup at the given live-cell density.
    func seed(density: Double) {
        for i in 0..<count {
            let r = Double(splitmix64(UInt64(i)) >> 11) * (1.0 / 9_007_199_254_740_992.0)
            cur[i] = r < density ? 1 : 0
        }
    }

    func swapBuffers() {
        swap(&cur, &next)
    }

    /// Advance rows `r0..<r1` by one generation (periodic boundaries). Disjoint
    /// row ranges run concurrently.
    func step(_ r0: Int, _ r1: Int) {
        let w = width, h = height
        let c = cur, nx = next
        for y in r0..<r1 {
            let up = ((y - 1 + h) % h) * w
            let dn = ((y + 1) % h) * w
            let row = y * w
            for x in 0..<w {
                let xL = (x - 1 + w) % w
                let xR = (x + 1) % w
                let neighbours = c[up + xL] + c[up + x] + c[up + xR]
                    + c[row + xL] + c[row + xR]
                    + c[dn + xL] + c[dn + x] + c[dn + xR]
                nx[row + x] = (neighbours == 3 || (c[row + x] == 1 && neighbours == 2)) ? 1 : 0
            }
        }
    }

    func snapshot() -> [UInt8] {
        Array(UnsafeBufferPointer(start: cur, count: count))
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

func runSequential(_ board: Board, steps: Int) {
    for _ in 0..<steps {
        board.step(0, board.height)
        board.swapBuffers()
    }
}

// MARK: 2. Coltrane spawn/join

func runColtrane(_ board: Board, steps: Int, bands: [(Int, Int)]) {
    for _ in 0..<steps {
        let handles = bands.map { band in
            Coltrane.shared.spawn { board.step(band.0, band.1) }
        }
        for handle in handles {
            handle.join()
        }
        board.swapBuffers()
    }
}

// MARK: 3. Swift async/await

func runAsync(_ board: Board, steps: Int, bands: [(Int, Int)]) async {
    for _ in 0..<steps {
        await withTaskGroup(of: Void.self) { group in
            for band in bands {
                group.addTask { board.step(band.0, band.1) }
            }
            for await _ in group {}
        }
        board.swapBuffers()
    }
}

// MARK: Output

func checksum(_ cells: [UInt8]) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for x in cells {
        h = (h ^ UInt64(x)) &* 1_099_511_628_211
    }
    return h
}

func liveCount(_ cells: [UInt8]) -> Int {
    cells.reduce(0) { $0 + Int($1) }
}

func writePGM(_ cells: [UInt8], width: Int, height: Int, to path: String) {
    var bytes = [UInt8](repeating: 0, count: width * height)
    for i in cells.indices {
        bytes[i] = cells[i] == 1 ? 255 : 0
    }
    var data = Data("P5\n\(width) \(height)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do { try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(width)x\(height))")
    } catch { print("could not write \(path): \(error)") }
}

func asciiPreview(_ cells: [UInt8], width: Int, height: Int, columns: Int = 72) {
    let step = max(1, width / columns)
    var output = ""
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            output.append(cells[y * width + x] == 1 ? "#" : " ")
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

func report(_ label: String, _ cells: [UInt8], since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(
        format: "%@ live=%d checksum=%016llx  (%.1f ms)",
        padded,
        liveCount(cells),
        checksum(cells),
        elapsedMilliseconds(since: start)
    ))
}

// MARK: Driver

let size = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 2048) : 2048
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let steps = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 300) : 300
let width = size, height = size
let chunks = maxVPs
print("board \(width)x\(height)  steps=\(steps)  maxVPs=\(maxVPs)  chunks=\(chunks)")

let board = Board(width: width, height: height)
let bands = rowBands(height, chunks)
let density = 0.3

// 1. Sequential
board.seed(density: density)
let seqStart = Date()
runSequential(board, steps: steps)
let sequential = board.snapshot()
report("sequential", sequential, since: seqStart)

// 2. Coltrane spawn/join
board.seed(density: density)
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat per-row fan-out
let coltraneStart = Date()
runColtrane(board, steps: steps, bands: bands)
let coltrane = board.snapshot()
report("coltrane (\(maxVPs) VP)", coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
board.seed(density: density)
let asyncStart = Date()
await runAsync(board, steps: steps, bands: bands)
let asynchronous = board.snapshot()
report("async/await", asynchronous, since: asyncStart)

precondition(
    sequential == coltrane && coltrane == asynchronous,
    "all three approaches must produce the identical board"
)

print("")
asciiPreview(coltrane, width: width, height: height)
writePGM(coltrane, width: width, height: height, to: "life.pgm")
