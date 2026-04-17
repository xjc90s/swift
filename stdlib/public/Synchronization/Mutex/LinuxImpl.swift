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

  @available(SwiftStdlib 6.0, *)
  @_alwaysEmitIntoClient
  @_transparent
  public init() {
    storage = Atomic(.unlocked)
  }
}

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

  // Slow path for `_lock`: runs a bounded adaptive spin, then parks in the kernel via FUTEX_WAIT. The spin is adaptive in two
  // senses: the number of CPU pauses issued per iteration grows exponentially round-to-round, and its upper bound is
  // re-chosen each iteration from the lock state we just observed. The exact upper-bound values and reasoning are inline at
  // the `maxPauseCount` declaration below.
  //
  // `selfId` is retained only to preserve the mangled ABI symbol for clients compiled against the previous PI-futex
  // implementation; the plain-futex code has no need for a thread id.
  @available(SwiftStdlib 6.0, *)
  @usableFromInline
  internal borrowing func _lockSlow(_ selfId: UInt32) {
    // Before relinquishing control to the kernel to block this particular
    // thread, run a little spin lock to keep this thread busy in the scenario
    // where the current owner thread's critical section is somewhat quick. We
    // avoid a lot of the syscall overhead in these cases which allow both the
    // owner thread and this current thread to do the user-space atomic for
    // releasing and acquiring (assuming no existing waiters).
    do {
      // Total spin-loop iterations we are willing to run before giving up and asking the kernel to park us.
      var spinsRemaining: Int = 14

      // Number of `_spinLoopHint()` CPU pauses we will issue on the current iteration before re-checking the lock word.
      // Grows exponentially (4 -> 8 -> 16 -> 32) up to the per-iteration `maxPauseCount`. The initial value of 4 is a floor
      // chosen over 1 to skip the first few iterations where the lock state has not yet had time to change and tight
      // back-to-back loads would generate wasted cache traffic for no information gain.
      var pauseCount: UInt32 = 4

      repeat {
        // Do a relaxed load of the futex value to prevent introducing a memory
        // barrier on each iteration of this loop. We're already informing the
        // CPU that this is a spin loop via the '_spinLoopHint' call which
        // should hopefully slow down the loop a considerable amount to view an
        // actually change in the value potentially. An extra memory barrier
        // would make it even slower on top of the fact that we may not even be
        // able to attempt to acquire the lock.
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

        spinsRemaining &-= 1

        // Upper bound on `pauseCount` for this iteration - i.e. the maximum number of `_spinLoopHint()` CPU pauses we will
        // issue before re-checking the lock word. Chosen per iteration from the state we just observed:
        //
        //   state == contended (at least one waiter is parked in the kernel):
        //     maxPauseCount = 6.
        //     Short pauses let us re-check the lock word often enough to catch the narrow release window when the owner
        //     unlocks, before the kernel wakes the parked waiter.
        //
        //   state == locked, or state == unlocked but our CAS just lost:
        //     maxPauseCount = 32.
        //     Long pauses give the owner (or the thread that just beat us to the CAS) CPU time to finish its critical
        //     section, and avoid generating exclusive-state cache traffic that would fight the owner's access to the lock.
        let maxPauseCount: UInt32 = (state == .contended) ? 6 : 32

        // Inform the CPU that we're doing a spin loop which should have the
        // effect of slowing down this loop if only by a little to preserve
        // energy.
        for _ in 0 ..< pauseCount {
          _spinLoopHint()
        }

        if pauseCount < maxPauseCount {
          // Exponential doubling to back off.
          pauseCount &<<= 1
        } else if pauseCount > maxPauseCount {
          // The cap just dropped - e.g. the lock state flipped from `locked` to `contended` on this iteration, so
          // `maxPauseCount` went from 32 down to 6 while `pauseCount` had already grown to 8, 16, or 32. Force `pauseCount`
          // back down to the new ceiling so the short-pause budget takes effect on the very next iteration.
          pauseCount = maxPauseCount
        }
      } while spinsRemaining > 0
    }

    // We've exhausted our spins. Mark the lock contended and ask the kernel to block for us until the owner releases.
    //
    // exchange(contended) marks the lock "has waiters" unconditionally. If the previous value was `unlocked` the owner released
    // between our last spin iteration and this exchange - we have just acquired (the next unlock will emit one spurious
    // FUTEX_WAKE, which is harmless). Otherwise the lock is still held and `*word == contended`, so the next unlock is
    // guaranteed to wake us.
    while true {
      let prev = storage.exchange(.contended, ordering: .acquiring)
      if prev == .unlocked {
        // Locked!
        return
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
    // Do a user space cmpxchg to see if we can easily acquire the lock. The lock word goes from `unlocked` directly to
    // `locked` on success - there is no intermediate state and no kernel involvement.
    if storage.compareExchange(
      expected: .unlocked,
      desired: .locked,
      successOrdering: .acquiring,
      failureOrdering: .relaxed
    ).exchanged {
      // Locked!
      return true
    }

    // The CAS failed, so the lock is currently held by someone else. Plain futex has no kernel-side recovery path that could
    // change that answer, so fall through to `_tryLockSlow` which just returns false.
    return _tryLockSlow()
  }

  @available(SwiftStdlib 6.0, *)
  @usableFromInline
  internal borrowing func _tryLockSlow() -> Bool {
    // Retained for ABI compatibility with clients compiled against the prior PI-futex implementation whose inlined `_tryLock`
    // bodies reference this mangled symbol. Plain futex has no kernel-side trylock recovery path, so if the userspace CAS in
    // `_tryLock` failed the lock is simply held by someone else.
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
    // Wake exactly one parked waiter. Any other parked waiters, plus threads still spinning on the acquire path, will
    // compete for the lock on the next release. FUTEX_WAKE's return value (count actually woken) is not needed here - a
    // wake targeting an already-departed waiter is harmless.
    _ = storage._futexWake(count: 1)
  }
}
