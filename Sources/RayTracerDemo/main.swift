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

// RayTracerDemo — render a small sphere scene with reflections, three ways:
//
//   1. Sequential   — trace every row on one thread.
//   2. Coltrane     — one spawn/join per image row.
//   3. async/await  — one child task per row in a TaskGroup.
//
// Flat data-parallel like the Mandelbrot demo, but the per-pixel cost is very
// *uneven*: a ray that misses everything is cheap, while one that hits a mirror
// sphere recurses to the reflection-depth limit. Those heavy pixels cluster, so
// rows differ wildly in cost — exactly where work-helping balances the load (an
// idle VP pulls the next pending row). Tracing is deterministic, so all three
// produce the identical image, which they assert. The result is written as a
// colour PPM.
//
// Usage: RayTracerDemo [size] [maxVPs] [samples]   (defaults: 1000, 8, 2)
// `samples` is anti-aliasing rays per axis (2 → 4 rays/pixel).

import Coltrane
import Foundation

// swiftlint:disable identifier_name

struct Vec3 {

    var x: Double
    var y: Double
    var z: Double

    static func + (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    static func - (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    static func * (a: Vec3, s: Double) -> Vec3 {
        Vec3(x: a.x * s, y: a.y * s, z: a.z * s)
    }

    static func * (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(x: a.x * b.x, y: a.y * b.y, z: a.z * b.z)
    }

    static func += (a: inout Vec3, b: Vec3) {
        a = a + b
    }

    var lengthSquared: Double {
        x * x + y * y + z * z
    }

    var normalized: Vec3 {
        self * (1 / lengthSquared.squareRoot())
    }
}

func dot(_ a: Vec3, _ b: Vec3) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
}

func reflect(_ d: Vec3, _ n: Vec3) -> Vec3 {
    d - n * (2 * dot(d, n))
}

struct Ray {

    var origin: Vec3
    var dir: Vec3
}

struct Sphere {

    var center: Vec3
    var radius: Double
    var color: Vec3
    var reflectivity: Double
    var checker: Bool

    /// Nearest positive intersection distance along `ray`, if any.
    func hit(_ ray: Ray) -> Double? {
        let oc = ray.origin - center
        let b = dot(oc, ray.dir)
        let c = oc.lengthSquared - radius * radius
        let disc = b * b - c
        if disc < 0 { return nil }
        let s = disc.squareRoot()
        let t0 = -b - s
        if t0 > 1e-4 { return t0 }
        let t1 = -b + s
        if t1 > 1e-4 { return t1 }
        return nil
    }
}

// Scene: a checkered floor (giant sphere) plus three spheres, one a mirror.
let spheres = [
    Sphere(
        center: Vec3(x: 0, y: -1000, z: 0),
        radius: 1000,
        color: Vec3(x: 1, y: 1, z: 1),
        reflectivity: 0,
        checker: true
    ),
    Sphere(
        center: Vec3(x: 0, y: 1, z: 0),
        radius: 1,
        color: Vec3(x: 0.9, y: 0.9, z: 0.95),
        reflectivity: 0.85,
        checker: false
    ),
    Sphere(
        center: Vec3(x: -2.2, y: 1, z: -0.4),
        radius: 1,
        color: Vec3(x: 0.9, y: 0.25, z: 0.2),
        reflectivity: 0.1,
        checker: false
    ),
    Sphere(
        center: Vec3(x: 2.2, y: 1, z: -0.4),
        radius: 1,
        color: Vec3(x: 0.2, y: 0.5, z: 0.9),
        reflectivity: 0.35,
        checker: false
    )
]
let sunDir = Vec3(x: -0.7, y: -1.0, z: -0.5).normalized
let toSun = sunDir * -1
let ambient = 0.15

func skyColor(_ dir: Vec3) -> Vec3 {
    let t = 0.5 * (dir.y + 1)
    return Vec3(x: 1, y: 1, z: 1) * (1 - t) + Vec3(x: 0.45, y: 0.65, z: 1.0) * t
}

func floorColor(_ point: Vec3) -> Vec3 {
    let tile = Int(floor(point.x)) + Int(floor(point.z))
    return tile & 1 == 0 ? Vec3(x: 0.85, y: 0.85, z: 0.85) : Vec3(x: 0.12, y: 0.12, z: 0.12)
}

func trace(_ ray: Ray, _ depth: Int) -> Vec3 {
    var nearest = Double.greatestFiniteMagnitude
    var hitSphere: Sphere?
    for sphere in spheres {
        if let t = sphere.hit(ray), t < nearest { nearest = t
            hitSphere = sphere
        }
    }
    guard let sphere = hitSphere else { return skyColor(ray.dir) }

    let point = ray.origin + ray.dir * nearest
    let normal = (point - sphere.center).normalized
    let base = sphere.checker ? floorColor(point) : sphere.color

    let shadowRay = Ray(origin: point + normal * 1e-4, dir: toSun)
    let lit = spheres.contains { $0.hit(shadowRay) != nil } ? 0.0 : max(0, dot(normal, toSun))
    var color = base * (ambient + lit * (1 - ambient))

    if sphere.reflectivity > 0, depth > 0 {
        let reflected = trace(Ray(origin: point + normal * 1e-4, dir: reflect(ray.dir, normal)), depth - 1)
        color = color * (1 - sphere.reflectivity) + reflected * sphere.reflectivity
    }
    return color
}

// MARK: Camera

let size = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1000) : 1000
let maxVPs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 8) : 8
let samples = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 2) : 2
let maxDepth = 8
let width = size, height = size

let camOrigin = Vec3(x: 0, y: 1.6, z: 5)
let lookAt = Vec3(x: 0, y: 0.9, z: 0)
let aspect = Double(width) / Double(height)
let halfHeight = tan((45.0 * .pi / 180) / 2)
let halfWidth = aspect * halfHeight
let camW = (camOrigin - lookAt).normalized
let camU = cross(Vec3(x: 0, y: 1, z: 0), camW).normalized
let camV = cross(camW, camU)
let lowerLeft = camOrigin - camU * halfWidth - camV * halfHeight - camW
let horizontal = camU * (2 * halfWidth)
let vertical = camV * (2 * halfHeight)

func renderRow(_ y: Int) -> [Vec3] {
    var row = [Vec3](repeating: Vec3(x: 0, y: 0, z: 0), count: width)
    let inv = 1.0 / Double(samples)
    let norm = 1.0 / Double(samples * samples)
    for x in 0..<width {
        var acc = Vec3(x: 0, y: 0, z: 0)
        for sy in 0..<samples {
            let t = 1 - (Double(y) + (Double(sy) + 0.5) * inv) / Double(height)
            for sx in 0..<samples {
                let s = (Double(x) + (Double(sx) + 0.5) * inv) / Double(width)
                let dir = (lowerLeft + horizontal * s + vertical * t - camOrigin).normalized
                acc += trace(Ray(origin: camOrigin, dir: dir), maxDepth)
            }
        }
        row[x] = acc * norm
    }
    return row
}

// MARK: 2. Coltrane spawn/join

func renderColtrane() -> [Vec3] {
    let handles = (0..<height).map { y in Coltrane.shared.spawn { renderRow(y) } }
    return handles.flatMap { $0.join() }
}

// MARK: 3. Swift async/await

func renderAsync() async -> [Vec3] {
    await withTaskGroup(of: (Int, [Vec3]).self) { group in
        for y in 0..<height {
            group.addTask { (y, renderRow(y)) }
        }
        var rows = [[Vec3]](repeating: [], count: height)
        for await (y, row) in group {
            rows[y] = row
        }
        return rows.flatMap(\.self)
    }
}

// MARK: Output

func checksum(_ image: [Vec3]) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for c in image {
        h = (h ^ c.x.bitPattern) &* 1_099_511_628_211
        h = (h ^ c.y.bitPattern) &* 1_099_511_628_211
        h = (h ^ c.z.bitPattern) &* 1_099_511_628_211
    }
    return h
}

func toByte(_ value: Double) -> UInt8 {
    UInt8(max(0, min(255, (max(0, min(1, value)).squareRoot()) * 255))) // gamma 2.0
}

func writePPM(_ image: [Vec3], width: Int, height: Int, to path: String) {
    var bytes = [UInt8]()
    bytes.reserveCapacity(image.count * 3)
    for c in image {
        bytes.append(toByte(c.x))
        bytes.append(toByte(c.y))
        bytes.append(toByte(c.z))
    }
    var data = Data("P6\n\(width) \(height)\n255\n".utf8)
    data.append(contentsOf: bytes)
    do { try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(width)x\(height))")
    } catch { print("could not write \(path): \(error)") }
}

func asciiPreview(_ image: [Vec3], width: Int, height: Int, columns: Int = 72) {
    let ramp = Array(" .:-=+*#%@")
    let step = max(1, width / columns)
    var output = ""
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let c = image[y * width + x]
            let luma = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
            output.append(ramp[min(ramp.count - 1, Int(max(0, min(1, luma)) * Double(ramp.count - 1) + 0.5))])
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

func report(_ label: String, _ image: [Vec3], since start: Date) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print(String(format: "%@ checksum=%016llx  (%.1f ms)", padded, checksum(image), elapsedMilliseconds(since: start)))
}

// MARK: Driver

print("image \(width)x\(height)  maxVPs=\(maxVPs)  samples=\(samples * samples)/px  maxDepth=\(maxDepth)")

// 1. Sequential
let seqStart = Date()
let sequential = (0..<height).flatMap { renderRow($0) }
report("sequential", sequential, since: seqStart)

// 2. Coltrane spawn/join
Coltrane.shared.initialize(maxVPs: maxVPs)
Coltrane.shared.helpingStrategy = .anywhere // uneven rows: help with any pending row
let coltraneStart = Date()
let coltrane = renderColtrane()
report("coltrane (\(maxVPs) VP)", coltrane, since: coltraneStart)
Coltrane.shared.terminate()

// 3. Swift async/await
let asyncStart = Date()
let asynchronous = await renderAsync()
report("async/await", asynchronous, since: asyncStart)

precondition(
    checksum(sequential) == checksum(coltrane) && checksum(coltrane) == checksum(asynchronous),
    "all three approaches must render the identical image"
)

print("")
asciiPreview(coltrane, width: width, height: height)
writePPM(coltrane, width: width, height: height, to: "raytrace.ppm")
