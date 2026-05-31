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

/// A typed handle to a spawned job, returned by `Coltrane.spawn`.
///
/// The handle holds a strong reference to its underlying job, so `join()` and
/// `fetch()` can always resolve it. `T` is the type the job produces.
public struct JobHandle<T: Sendable>: Sendable {

    // MARK: - Properties

    /// The underlying job this handle refers to.
    let job: Job<T>

    /// Whether the job has finished producing its result.
    public var isComplete: Bool {
        Coltrane.shared.isComplete(job)
    }

    // MARK: - Public

    /// Waits for the job to finish and returns its result, helping to run the
    /// job — or other pending work — on the calling processor in the meantime.
    @discardableResult
    public func join() -> T {
        Coltrane.shared.join(job)
        return job.storedResult
    }

    /// Waits for the job to finish and returns its result without contributing
    /// work, leaving the job in the graph.
    @discardableResult
    public func fetch() -> T {
        Coltrane.shared.fetch(job)
        return job.storedResult
    }
}
