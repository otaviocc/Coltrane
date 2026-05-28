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

/// Split/merge fan-out built on top of `spawn`/`join`.
package extension Runtime {

    // MARK: - Public

    /// Splits `data` into `splitFactor` pieces, runs `body` on each in parallel,
    /// and merges their results.
    ///
    /// `split(data, splitFactor, index)` produces the input for piece `index`;
    /// `merge` combines the per-piece results in order. Returns a handle whose
    /// `join()` yields the merged result.
    ///
    /// - Precondition: `splitFactor > 0`.
    @discardableResult
    func spawnSplit<Input: Sendable, T: Sendable>(
        data: Input,
        splitFactor: Int,
        options: JobOptions = .init(),
        split: @escaping (Input, Int, Int) -> Input,
        merge: @escaping ([T]) -> T,
        _ body: @escaping (Input) -> T
    ) -> JobHandle<T> {
        precondition(splitFactor > 0, "splitFactor must be > 0")

        return spawn(options: options) { [unowned self] in
            var handles: [JobHandle<T>] = []
            handles.reserveCapacity(splitFactor)
            for index in 0..<splitFactor {
                let piece = split(data, splitFactor, index)
                handles.append(spawn { body(piece) })
            }
            let results = handles.map { $0.join() }
            return merge(results)
        }
    }
}
