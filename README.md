# Coltrane

A Swift runtime that builds on the ideas of **Anahy**, the multithreaded scheduling model
introduced in the VECPAR 2006 paper
[*Anahy: A Programming Environment for Cluster Computing*](https://link.springer.com/chapter/10.1007/978-3-540-71351-7_16):
a library for describing application *concurrency* (logical threads + data dependencies) and
letting a runtime schedule it onto the *parallelism* the hardware provides (real threads pinned to
cores). Single-machine, multi-core; the cluster layer of the original model is out of scope.

You write `spawn`/`join` and never reason about cores or thread pools. The runtime builds a
**DAG** of tasks implicitly from the nesting of `spawn` calls and schedules it onto a fixed pool of
**Virtual Processors** (one OS thread per core) using **work-helping**: an idle or joining VP
executes pending descendant tasks itself rather than blocking.

> This is a deliberate alternative to Swift Structured Concurrency. The core is built on raw
> threads + locks (`Thread`, `NSCondition`, `NSRecursiveLock`, `DispatchSemaphore`) — there is no
> `async`/`await`, no actors, and no stack switching. Jobs run inline on a VP's real call stack.

## Example

```swift
import Coltrane

func fibonacci(_ n: Int) -> Int {
    guard n > 1 else { return n }
    if n <= 20 { return fibonacci(n - 1) + fibonacci(n - 2) }   // sequential cutoff
    let a = Runtime.shared.spawn { fibonacci(n - 1) }           // spawn a task
    let b = Runtime.shared.spawn { fibonacci(n - 2) }
    return a.join() + b.join()                                  // join both
}

Runtime.shared.initialize(maxVPs: 4)
print(Runtime.shared.spawn { fibonacci(35) }.join())           // 9227465
Runtime.shared.terminate()
```

The core invariant: the result is **independent of the VP count**. `fibonacci(35)` is `9227465`
on 1, 2, 4, or 8 VPs.

## API

The API is declared with `package` visibility — it's consumed by the demos and tests in this
package, not exported to external importers. The internals (`Job`, `JobList`, `VirtualProcessor`,
the scheduler) are `internal`/`private`; tests reach them via `@testable import`.

- `Runtime.shared.initialize(maxVPs:)` / `terminate()` — lifecycle. The calling thread becomes VP 0.
- `spawn(options:_:) -> JobHandle<T>` — create a logical task.
- `JobHandle<T>.join() -> T` — active sync: run the task (or other descendants) yourself, then return.
- `JobHandle<T>.fetch() -> T` — passive sync: wait for the result without contributing work.
- `spawnSplit(data:splitFactor:split:merge:_:)` — fan a value into sub-tasks and merge the results.
- `Runtime.shared.helpingStrategy` — `.anywhere` / `.currentSubtree` / `.joinedSubtree` (default),
  where a joining VP looks for work to help with.

## Build, test, run

```sh
swift build
swift test                 # 19 tests; Fibonacci/Mandelbrot/N-body correctness, split/merge, join semantics
swift run -c release FiboDemo                # fib(35) three ways: sequential, Coltrane, async/await
swift run -c release FiboDemo 38 8 30        # fib(38), 8 VPs, sequential-cutoff 30
swift run -c release MandelbrotDemo          # 1000x1000 Mandelbrot three ways → mandelbrot.pgm
swift run -c release MandelbrotDemo 1500 12 1000  # size, maxVPs, maxIter
swift run -c release NBodyDemo               # 50000-body Barnes–Hut three ways → nbody.pgm
swift run -c release NBodyDemo 100000 12 30  # bodies, maxVPs, sim steps
```

Three demos, each computing the **same** thing three ways — plain recursion/loops, Coltrane
`spawn`/`join`, and Swift `async`/`await` — timed and asserted to agree (async/await appears only in
the demos; the core library has none). Use a release build for meaningful timings.

- **`FiboDemo`** — recursive Fibonacci (deep, fine-grained fork/join). Uses the default
  `joinedSubtree` helping policy. ~6× on 8 VPs.
- **`MandelbrotDemo`** — Mandelbrot set, one job per image row (flat, coarse data-parallelism).
  Sets `helpingStrategy = .anywhere` so a joining VP can help with *any* pending row, not just
  descendants of the one it's waiting on — the right policy for flat fan-out. Writes `mandelbrot.pgm`.
  ~4.3× on 8 VPs; the per-row granularity (matched to the async version for fairness) makes the
  single root-list lock the ceiling — coarser row-chunks would push it higher.
- **`NBodyDemo`** — gravitational N-body with a Barnes–Hut quadtree. The tree build is sequential
  shared work; the per-body force evaluation reads the finished tree with no locks and parallelizes
  cleanly (chunked, `.anywhere` policy). The forces are bit-identical across all three methods (each body
  sums over the tree in a fixed order). ~6.5× on 8 VPs, on par with async/await at matched cores.
  Writes a `nbody.pgm` density image. The tree is a **flat array of value-type cells traversed via
  `UnsafeBufferPointer`**, not a graph of class nodes — a class-based tree shared across threads
  spends the force loop doing atomic ARC retain/release on shared objects, which capped *both*
  Coltrane and async/await near ~1.4× until this was fixed.

### Thread Sanitizer

`swift test --sanitize=thread` is the intended race check, but on this machine the toolchain's
bundled `libclang_rt.tsan_osx_dynamic.dylib` segfaults inside its own `__tsan::InitializePlatform`
at dyld-init time (before `main`) — it crashes even on a trivial `print(...)` program, so it is an
environment/toolchain incompatibility, not a property of this code. Until the toolchain is updated,
race resistance is exercised dynamically: repeated high-VP runs and rapid init/terminate cycles.

## Source map

| File | Responsibility |
|---|---|
| `Runtime.swift` | lifecycle, eager VP pool, spawn, shared graph state |
| `Job.swift` | `JobStatus`, the `AnyJob` node protocol, and `Job<T>` |
| `JobList.swift` | lock-protected ordered list — one level of the task graph |
| `JobOptions.swift` | per-job attributes and processor affinity |
| `Scheduler.swift` | `storeJob`, `searchJobs`, `findHelpWork`, `executeJob` |
| `Join.swift` | `join` (helping loop), `fetch`, completion wait |
| `VirtualProcessor.swift` | worker run loop, idle backoff, core binding |
| `JobHandle.swift` | typed handle over `Job<T>` |
| `SpawnSplit.swift` | split/merge fan-out |

## Work-helping and scaling

The scheduler is tuned for deep, fine-grained fork/join (e.g. Fibonacci), where a naive design
barely benefits from extra cores. Two choices make it scale:

1. **A work-first helping loop.** A naive join helps with one unit of work and then blocks on a
   condition variable until the target finishes, leaving threads parked most of the time. Coltrane's
   `join` instead keeps working: it runs the target itself if still unclaimed, otherwise repeatedly
   executes pending work from the target's subtree, and only parks (briefly, with a short re-poll)
   when the whole subtree is already in flight on other VPs. This is the leapfrogging discipline used
   by real fork/join runtimes, and restricting helping to the joined job's subtree (the default
   `joinedSubtree` policy) also bounds a joiner's extra stack growth.
2. **An eager VP pool.** The pool is created once at `initialize()`; every spawned job is simply
   marked `.unassigned` and claimed by whichever VP reaches it first. The spawn path takes **no
   global scheduler lock** — idle workers re-poll on a 1 ms interval, so spawning never serializes on
   a shared mutex. (Creating a thread per spawn and handing it the job, by contrast, lets a parent
   park before any helper exists.)

Result (release build, fib(38), coarse tasks): roughly **2× / 3.4× / 6.1× / 7.5×** at 2 / 4 / 8 / 12
VPs. Run `swift run -c release FiboDemo` to see the three-way comparison; pass
`[n] [maxVPs] [cutoff]` to experiment.

## Other notes

- **Job removal / re-parenting:** in the join model children complete (and remove themselves)
  before the parent's join returns, so `JobList.remove(reparentingChildren:)` is a safety net that
  only does real work if a child outlives its parent.
- **`detached` jobs:** run with their result discarded and are spliced out on completion.
- **`fetch`:** passive — never executes the job, so it relies on another VP to run it.
- **Missing-job lookups:** a `JobHandle` holds a strong reference to its `Job`, so a join can never
  fail to find its job — what would be a lookup-failure error is instead an internal precondition.
- **Core affinity:** `pthread_setaffinity_np` on Linux, best-effort no-op on Darwin (Apple Silicon
  affinity hints are advisory). Affinity affects placement only, never correctness.
