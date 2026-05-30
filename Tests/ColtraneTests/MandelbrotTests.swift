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

import XCTest
@testable import Coltrane

// swiftlint:disable identifier_name

private func escapeIterations(cRe: Double, cIm: Double, maxIter: Int) -> Int {
    var zRe = 0.0, zIm = 0.0, iter = 0
    while iter < maxIter {
        let zRe2 = zRe * zRe, zIm2 = zIm * zIm
        if zRe2 + zIm2 > 4.0 { break }
        zIm = 2 * zRe * zIm + cIm
        zRe = zRe2 - zIm2 + cRe
        iter += 1
    }
    return iter
}

private func row(_ r: Int, width: Int, height: Int, maxIter: Int) -> [UInt16] {
    let centerRe = -0.75, centerIm = 0.0, half = 1.5
    let pixel = (2 * half) / Double(height)
    let reMin = centerRe - Double(width) * pixel / 2
    let cIm = centerIm - half + (Double(r) + 0.5) * pixel
    return (0..<width).map { col in
        UInt16(escapeIterations(cRe: reMin + (Double(col) + 0.5) * pixel, cIm: cIm, maxIter: maxIter))
    }
}

private func sequentialImage(width: Int, height: Int, maxIter: Int) -> [UInt16] {
    (0..<height).flatMap { row($0, width: width, height: height, maxIter: maxIter) }
}

final class MandelbrotTests: XCTestCase {

    func testParallelImageMatchesSequential() {
        let width = 64, height = 64, maxIter = 200
        let reference = sequentialImage(width: width, height: height, maxIter: maxIter)

        for strategy in [Coltrane.HelpingStrategy.anywhere, .joinedSubtree, .currentSubtree] {
            let runtime = Coltrane.shared
            runtime.initialize(maxVPs: 4)
            runtime.helpingStrategy = strategy

            let handles = (0..<height).map { r in
                runtime.spawn { row(r, width: width, height: height, maxIter: maxIter) }
            }
            let image = handles.flatMap { $0.join() }

            XCTAssertEqual(image, reference, "parallel image differs under \(strategy)")
            XCTAssertEqual(runtime.terminate(), 0)
        }
    }
}
