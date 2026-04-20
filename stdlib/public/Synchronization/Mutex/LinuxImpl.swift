//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Atomics open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _SynchronizationShims
#if canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

@_extern(c, "llvm.readcyclecounter")
internal func _readCycleCounter() -> UInt64

@inline(__always)
internal func _cycleCounter() -> UInt64 {
#if arch(i386) || arch(x86_64)
  return _readCycleCounter()
#else
  return 0
#endif
}

extension Atomic where Value == _MutexHandle.State {
  // Sleeps while the underlying word equals `expected`. Returns 0 on a normal
  // wake or the errno value (EAGAIN=11 and EINTR=4 are the expected retryable
  // cases).
  internal borrowing func _futexWait(expected: _MutexHandle.State) -> UInt32 {
    unsafe _swift_stdlib_futex_wait(.init(_rawAddress), expected.rawValue)
  }

  // Wakes up to `count` waiters parked on this word. Result is the number
  // woken (or errno on failure); callers typically discard it.
  internal borrowing func _futexWake(count: UInt32) -> UInt32 {
    unsafe _swift_stdlib_futex_wake(.init(_rawAddress), count)
  }
}

@available(SwiftStdlib 6.0, *)
extension _MutexHandle {
  @available(SwiftStdlib 6.0, *)
  @frozen
  @usableFromInline
  internal enum State: UInt32, AtomicRepresentable {
    case unlocked
    case locked      // held, no waiters parked in the kernel
    case contended   // held, at least one waiter parked in the kernel
  }
}

@available(SwiftStdlib 6.0, *)
@frozen
@_staticExclusiveOnly
public struct _MutexHandle: ~Copyable {
  @usableFromInline
  let storage: Atomic<State>

  // Approximate count of threads currently in `_lockSlow`'s kernel phase. Read by the entry depth gate;
  // inexact (e.g. counts briefly run between wake and retry), but used only as a hint.
  @usableFromInline
  let slowPathDepth: Atomic<UInt32>

  @available(SwiftStdlib 6.0, *)
  @_alwaysEmitIntoClient
  @_transparent
  public init() {
    storage = Atomic(.unlocked)
    slowPathDepth = Atomic(0)
  }
}

// Spin-phase iteration budget.
private let spinTries: Int = 20

// CPU pauses per spin iteration, before jitter. Must be a power of two (masked to generate the jitter via
// `jitter & (pauseBase - 1)`).
private let pauseBase: UInt32 = 64

// Once this many threads are already waiting for the lock, new arrivals skip the spin loop and go to sleep
// immediately. Keeps the set of actively-spinning threads bounded so the lock holder's critical section runs
// without cache-line interference from the spinners.
private let maxActiveSpinners: UInt32 = 4

@available(SwiftStdlib 6.0, *)
extension _MutexHandle {
  @available(SwiftStdlib 6.0, *)
  @_alwaysEmitIntoClient
  @_transparent
  internal borrowing func _lock() {
    let (exchanged, _) = storage.compareExchange(
      expected: .unlocked,
      desired: .locked,
      successOrdering: .acquiring,
      failureOrdering: .relaxed
    )

    if _fastPath(exchanged) {
      // Locked!
      return
    }

    _lockSlow(0)
  }

  // Slow path for `_lock`:
  //   - Depth gate: if the queue is already deep, skip straight to parking. Bounds tail latency and keeps the spinner
  //     pool small so the owner's critical section runs uncontested.
  //   - Spin: bounded pause-based spin with per-thread jitter. Stops early if the lock is observed contended, so we
  //     don't steal it from a thread the kernel is about to wake.
  //   - Kernel: loop try-acquire plus FUTEX_WAIT until acquired. A thread that has to park bumps `slowPathDepth` on
  //     its first failed try-acquire and drops it on successful acquire. This feeds the depth gate: once enough
  //     threads are parked, new arrivals skip spinning and park directly, which stops spinners from stealing the
  //     lock out from under parked threads and bounds tail latency. Threads that win the initial try-acquire never
  //     touch the counter.
  //
  // `selfId` is retained only to preserve the mangled ABI symbol from the prior PI-futex implementation.
  @available(SwiftStdlib 6.0, *)
  @usableFromInline
  internal borrowing func _lockSlow(_ selfId: UInt32) {
    // Skip the spin when the queue is already deep - extra spinners just slow down the parked threads' handoff.
    let initialState = storage.load(ordering: .acquiring)
    let depth = slowPathDepth.load(ordering: .acquiring)
    let skipSpin = (initialState == .contended) && (depth >= maxActiveSpinners)

    if !skipSpin {
      // Cycle-counter low bits provide per-thread jitter to de-correlate pause timings across threads released
      // together by a lock handoff.
      let jitter = UInt32(truncatingIfNeeded: _cycleCounter())
      let mask = pauseBase &- 1
      var spinsRemaining = spinTries

      while spinsRemaining > 0 {
        let state = storage.load(ordering: .relaxed)

        if state == .unlocked, storage.compareExchange(
          expected: .unlocked,
          desired: .locked,
          successOrdering: .acquiring,
          failureOrdering: .relaxed
        ).exchanged {
          // Locked!
          return
        }

        // Don't steal the lock from a thread the kernel is about to wake.
        if state == .contended { break }

        // Inform the CPU that we're doing a spin loop which should have the
        // effect of slowing down this loop if only by a little to preserve
        // energy.
        let pauses = pauseBase &+ (jitter & mask)
        for _ in 0 ..< pauses {
          _spinLoopHint()
        }

        spinsRemaining -= 1
      }
    }

    var visibleToSpinners = false

    while true {
      // `.contended`, not `.locked`: parked threads exist and must be woken by the next unlock.
      if storage.exchange(.contended, ordering: .acquiring) == .unlocked {
        if visibleToSpinners {
          _ = slowPathDepth.wrappingSubtract(1, ordering: .relaxed)
        }
        // Locked!
        return
      }

      // Didn't get the lock - either it's still held, or we were woken but a spinner / fast-path arrival got in first.
      if !visibleToSpinners {
        // Make arriving threads park instead of spinning, so parked threads can make progress.
        _ = slowPathDepth.wrappingAdd(1, ordering: .relaxed)
        visibleToSpinners = true
      }

      // Sleep while `*word == contended`. Returns 0 on a normal wake from FUTEX_WAKE, or an errno for retryable cases.
      let waitResult = storage._futexWait(expected: .contended)
      switch waitResult {
      // 0      - woken normally by FUTEX_WAKE from the unlocker
      // EAGAIN - *word changed before the kernel-side comparison; retry
      // EINTR  - signal-interrupted before sleep; retry
      case 0, 11, 4:
        continue

      default:
        // TODO: Replace with a colder function / one that takes a StaticString
        fatalError("Unknown error occurred while attempting to acquire a Mutex: \(waitResult)")
      }
    }
  }

  @available(SwiftStdlib 6.0, *)
  @_alwaysEmitIntoClient
  @_transparent
  internal borrowing func _tryLock() -> Bool {
    // Userspace CAS unlocked -> locked. Plain futex has no kernel-side recovery path, so if the CAS fails the lock is
    // held by someone else and no retry can change that.
    if storage.compareExchange(
      expected: .unlocked,
      desired: .locked,
      successOrdering: .acquiring,
      failureOrdering: .relaxed
    ).exchanged {
      // Locked!
      return true
    }

    return _tryLockSlow()
  }

  @available(SwiftStdlib 6.0, *)
  @usableFromInline
  internal borrowing func _tryLockSlow() -> Bool {
    // Retained only to preserve the mangled ABI symbol from the prior PI-futex implementation.
    return false
  }

  @available(SwiftStdlib 6.0, *)
  @_alwaysEmitIntoClient
  @_transparent
  internal borrowing func _unlock() {
    // If the previous value was `contended`, a waiter is parked in the kernel and we must wake one via FUTEX_WAKE.
    guard storage.exchange(.unlocked, ordering: .releasing) == .contended else {
      // Unlocked, syscall-free (the common case).
      return
    }

    _unlockSlow()
  }

  @available(SwiftStdlib 6.0, *)
  @usableFromInline
  internal borrowing func _unlockSlow() {
    // Wake exactly one parked waiter. Remaining parkers and newly-arriving spinners compete on the next release.
    _ = storage._futexWake(count: 1)
  }
}
