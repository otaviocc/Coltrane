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

// MandelbrotDemo — render the Mandelbrot set three ways, for comparison:
//
//   1. Plain recursion / loops — a single thread.
//   2. Coltrane spawn/join     — one job per image row, scheduled across VPs.
//   3. Swift async/await       — one child task per row in a TaskGroup.
//
// Unlike Fibonacci (recursive fork/join), this is a *flat data-parallel*
// workload: every row is independent, equal-ish coarse work. That makes it a
// good fit for the `.anywhere` helping policy — a joining VP can pick up any
// pending row, not just descendants of the row it happens to be waiting on.
//
// All three produce the identical image (verified by checksum). The Coltrane
// result is written to a PGM file and previewed as ASCII.
//
// Usage: MandelbrotDemo [size] [maxVPs] [maxIter]   (defaults: 1000, 8, 512)

import Coltrane
import Foundation

// swiftlint:disable identifier_name

// View window: the whole set, centered, with square pixels.
let centerRe = -0.75
let centerIm = 0.0
let halfExtent = 1.5

/// Iteration count until the orbit of `c` escapes |z| > 2, capped at `maxIter`.
/// `maxIter` means "did not escape" (inside the set).
@inline(__always)
func escapeIterations(cRe: Double, cIm: Double, maxIter: Int) -> Int {
    var zRe = 0.0, zIm = 0.0
    var iter = 0
    while iter < maxIter {
        let zRe2 = zRe * zRe
        let zIm2 = zIm * zIm
        // |z|² > 4 ⇔ |z| > 2, the escape radius: once outside, the orbit diverges.
        // Comparing squares avoids a square root.
        if zRe2 + zIm2 > 4.0 { break }
        // z ← z² + c, written out for the complex square (zRe² − zIm², 2·zRe·zIm).
        zIm = 2 * zRe * zIm + cIm
        zRe = zRe2 - zIm2 + cRe
        iter += 1
    }
    return iter
}

/// Compute one image row as escape counts. Pure and self-contained — the unit
/// of work parallelized by every approach below.
func mandelbrotRow(_ row: Int, width: Int, height: Int, maxIter: Int) -> [UInt16] {
    var out = [UInt16](repeating: 0, count: width)
    let pixel = (2 * halfExtent) / Double(height) // square pixels
    let reMin = centerRe - Double(width) * pixel / 2
    let cIm = centerIm - halfExtent + (Double(row) + 0.5) * pixel
    for col in 0..<width {
        let cRe = reMin + (Double(col) + 0.5) * pixel
        out[col] = UInt16(escapeIterations(cRe: cRe, cIm: cIm, maxIter: maxIter))
    }
    return out
}

// MARK: 1. Sequential

func mandelbrotSequential(width: Int, height: Int, maxIter: Int) -> [UInt16] {
    var image = [UInt16]()
    image.reserveCapacity(width * height)
    for row in 0..<height {
        image.append(contentsOf: mandelbrotRow(row, width: width, height: height, maxIter: maxIter))
    }
    return image
}

// MARK: 2. Coltrane spawn/join

func mandelbrotColtrane(width: Int, height: Int, maxIter: Int) -> [UInt16] {
    var handles: [JobHandle<[UInt16]>] = []
    handles.reserveCapacity(height)
    for row in 0..<height {
        handles.append(Coltrane.shared.spawn {
            mandelbrotRow(row, width: width, height: height, maxIter: maxIter)
        })
    }
    var image = [UInt16]()
    image.reserveCapacity(width * height)
    for handle in handles {
        image.append(contentsOf: handle.join())
    }
    return image
}

// MARK: 3. Swift async/await

func mandelbrotAsync(width: Int, height: Int, maxIter: Int) async -> [UInt16] {
    await withTaskGroup(of: (Int, [UInt16]).self) { group in
        for row in 0..<height {
            group.addTask {
                (row, mandelbrotRow(row, width: width, height: height, maxIter: maxIter))
            }
        }
        var rows = [[UInt16]](repeating: [], count: height)
        for await (row, data) in group {
            rows[row] = data
        }
        return rows.flatMap(\.self)
    }
}

// MARK: Output helpers

func checksum(_ image: [UInt16]) -> UInt64 {
    image.reduce(into: UInt64(0)) { $0 = $0 &+ UInt64($1) }
}

/// Write a binary grayscale PGM (P5). Inside-set pixels are black; escaping
/// pixels get a gamma-boosted gradient so the filaments stay visible.
func writePGM(_ image: [UInt16], width: Int, height: Int, maxIter: Int, to path: String) {
    var bytes = [UInt8](repeating: 0, count: width * height)
    for i in 0..<image.count {
        let it = Int(image[i])
        if it >= maxIter {
            bytes[i] = 0 // never escaped → inside the set → black
        } else {
            // Normalised escape time, gamma-curved (exponent < 1 brightens the
            // low end) so the fast-escaping filaments near the boundary stay visible.
            let t = Double(it) / Double(maxIter)
            bytes[i] = UInt8(max(0, min(255, 255 * pow(t, 0.35))))
        }
    }
    var data = Data("P5\n\(width) \(height)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(width)x\(height))")
    } catch {
        print("could not write \(path): \(error)")
    }
}

/// Render a small ASCII preview by sampling the image.
func asciiPreview(_ image: [UInt16], width: Int, height: Int, maxIter: Int, columns: Int = 72) {
    let ramp = Array(" .:-=+*#%@")
    let stepX = max(1, width / columns)
    let stepY = max(1, stepX * 2) // chars are ~twice as tall as wide
    var output = ""
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let it = Int(image[y * width + x])
            let index = it >= maxIter
                ? ramp.count - 1
                : min(ramp.count - 1, it * (ramp.count - 1) / max(1, maxIter))
            output.append(ramp[index])
            x += stepX
        }
        output.append("\n")
        y += stepY
    }
    print(output, terminator: "")
}

func elapsedMilliseconds(since start: Date) -> Double {
    Date().timeIntervalSince(start) * 1000
}

// MARK: Driver

let size = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1000) : 1000
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let maxIter = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 512) : 512
let width = size
let height = size
print("mandelbrot \(width)x\(height)  maxIter=\(maxIter)  maxVPs=\(maxVPs)")

// 1. Sequential
let seqStart = Date()
let sequential = mandelbrotSequential(width: width, height: height, maxIter: maxIter)
let seqMs = elapsedMilliseconds(since: seqStart)
print(String(format: "sequential       checksum=%llu  (%.1f ms)", checksum(sequential), seqMs))

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // flat fan-out: help with any pending row
let coltraneStart = Date()
let coltrane = mandelbrotColtrane(width: width, height: height, maxIter: maxIter)
let coltraneMs = elapsedMilliseconds(since: coltraneStart)
Coltrane.shared.terminate()
print(String(
    format: "coltrane (%d VP)  checksum=%llu  (%.1f ms, %.2fx)",
    maxVPs,
    checksum(coltrane),
    coltraneMs,
    seqMs / coltraneMs
))

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await mandelbrotAsync(width: width, height: height, maxIter: maxIter)
let asyncMs = elapsedMilliseconds(since: asyncStart)
print(String(
    format: "async/await      checksum=%llu  (%.1f ms, %.2fx)",
    checksum(asynchronous),
    asyncMs,
    seqMs / asyncMs
))

precondition(
    checksum(sequential) == checksum(coltrane) && checksum(coltrane) == checksum(asynchronous),
    "all three approaches must produce the same image"
)

print("")
asciiPreview(coltrane, width: width, height: height, maxIter: maxIter)
writePGM(coltrane, width: width, height: height, maxIter: maxIter, to: "mandelbrot.pgm")
