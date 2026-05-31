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

import Foundation

/// Scheduling attributes for a spawned job.
///
/// Pass an instance to `Coltrane.spawn(options:_:)` to control how the job is
/// joined and placed. The defaults match an ordinary joinable task.
public struct JobOptions {

    // MARK: - Nested types

    /// Whether a job is expected to be joined or runs fire-and-forget.
    public enum DetachState {

        /// The job will be joined; its result is kept until then.
        case joinable
        /// The job is never joined; its result is discarded and it is removed
        /// from the graph as soon as it finishes.
        case detached
    }

    // MARK: - Properties

    /// Whether the job is joinable or detached. Defaults to `.joinable`.
    public var detachState: DetachState = .joinable
    /// How many times the job may be joined before it is removed from the
    /// graph. Defaults to `1`.
    public var maxJoins = 1
    /// Which virtual processor the job must run on. Defaults to `.any`.
    public var affinity: ProcessorAffinity = .any

    // MARK: - Life cycle

    /// Creates options with the default values.
    public init() {}
}

/// Pins a job to a particular virtual processor, or leaves it free to run on
/// any of them.
public enum ProcessorAffinity: Equatable {

    /// The job may be claimed and run by any virtual processor.
    case any
    /// The job may only be run by the virtual processor with this logical id.
    case specific(Int)
}
