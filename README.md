# Coltrane

A Swift runtime that builds on the ideas of **Anahy**, the multithreaded scheduling model introduced in the VECPAR 2006 paper [*Anahy: A Programming Environment for Cluster Computing*](https://link.springer.com/chapter/10.1007/978-3-540-71351-7_16): a library for describing application *concurrency* (logical threads and data dependencies) and letting a runtime schedule it onto the *parallelism* the hardware provides (real threads pinned to cores). Single-machine, multi-core. The cluster layer of the original model is out of scope.

You write `spawn`/`join` and never reason about cores or thread pools. The runtime builds a [**DAG**](https://en.wikipedia.org/wiki/Directed_acyclic_graph) of tasks implicitly from the nesting of `spawn` calls and schedules it onto a fixed pool of **Virtual Processors**, each a real OS thread with the pool sized to the core count by default, using **work-helping**: an idle or joining VP executes pending descendant tasks itself rather than blocking.

> This is a deliberate alternative to Swift Structured Concurrency. The core is built on raw threads and locks (`Thread`, `NSCondition`, `NSRecursiveLock`, `DispatchSemaphore`). There is no `async`/`await`, no actors, and no stack switching. Jobs run inline on a VP's real call stack.

## Example

```swift
import Coltrane

func fibonacci(_ n: Int) -> Int {
    guard n > 1 else { return n }
    if n <= 20 { return fibonacci(n - 1) + fibonacci(n - 2) } // sequential cutoff
    let a = Runtime.shared.spawn { fibonacci(n - 1) }
    let b = Runtime.shared.spawn { fibonacci(n - 2) }
    return a.join() + b.join()
}

Runtime.shared.initialize(maxVPs: 4)
print(Runtime.shared.spawn { fibonacci(35) }.join())
Runtime.shared.terminate()
```

Below the cutoff, the function recurses directly instead of spawning. A task that small costs more to schedule than to compute, so splitting only pays off for the coarser upper levels of the tree. Tune the threshold to the work per task. This is not specific to Coltrane. Every task runtime (including `async`/`await`) needs a cutoff for fine-grained recursion.

The core invariant: the result is **independent of the VP count**. `fibonacci(35)` is `9227465` on 1, 2, 4, or 8 VPs.

## API

- `Runtime.shared.initialize(maxVPs:)` / `terminate()`: start and stop the runtime. The calling thread becomes VP 0.
- `spawn(options:_:) -> JobHandle<T>`: create a task, returning a handle to its eventual result.
- `JobHandle<T>.join() -> T`: wait for the result, helping run pending work in the meantime.
- `JobHandle<T>.fetch() -> T`: wait for the result without contributing work.
- `JobHandle<T>.isComplete`: whether the result is ready.
- `spawnSplit(data:splitFactor:split:merge:_:)`: fan a value into sub-tasks and merge their results.
- `JobOptions`: per-task options: `maxJoins`, `detachState`, and `affinity` (`ProcessorAffinity`).
- `Runtime.shared.helpingStrategy`: `.anywhere` / `.currentSubtree` / `.joinedSubtree` (default): where a joining VP looks for work to help with.

## Build and Test

```sh
swift build
swift test
```

## Demos

Each demo computes the same result three ways: plain recursion/loops, Coltrane `spawn`/`join`, and Swift `async`/`await`. It times them and asserts they agree (async/await appears only in the demos. The core library has none). Use a release build for meaningful timings.

### FiboDemo

```sh
swift run -c release FiboDemo
swift run -c release FiboDemo 38 8 30
```

Recursive Fibonacci: deep, fine-grained fork/join, using the default `joinedSubtree` helping policy. Arguments: `[n] [maxVPs] [cutoff]`. Scales roughly 6x on 8 VPs.

### MandelbrotDemo

```sh
swift run -c release MandelbrotDemo
swift run -c release MandelbrotDemo 1500 12 1000
```

The Mandelbrot set, one job per image row: flat, coarse data-parallelism. Sets `helpingStrategy = .anywhere` so a joining VP can help with any pending row. Writes a viewable `mandelbrot.pgm`. Arguments: `[size] [maxVPs] [maxIter]`. Scales roughly 5x on 8 VPs.

### NBodyDemo

```sh
swift run -c release NBodyDemo
swift run -c release NBodyDemo 100000 12 30
```

Gravitational N-body with a Barnes–Hut quadtree: a sequential tree build, then a lock-free per-body force evaluation (chunked, `.anywhere` policy) that is bit-identical across all three methods. The tree is a flat array of value-type cells traversed via `UnsafeBufferPointer` (not a graph of class nodes, which would cap scaling with ARC traffic on shared objects). Writes an `nbody.pgm` density image. Arguments: `[bodies] [maxVPs] [steps]`. Scales roughly 7x on 8 VPs.
