## macOS futex-emulation semantics
##
## insideout's futex API is backed by Linux `futex(2)`; on macOS it is
## emulated with the undocumented `__ulock_wait`/`__ulock_wake` syscalls
## (see insideout/futexes.nim).  This test asserts that the emulation
## reproduces the error outcomes the rest of the runtime depends upon:
##
## * a timed `wait` that is never woken reports `ETIMEDOUT`
## * a `wait` whose compare value no longer matches reports `EAGAIN`
## * `waitMask` likewise reports `EAGAIN` on a value mismatch
##
## Guarded to Darwin/BSD: it specifically exercises the ulock emulation
## path; the native `futex(2)` path is already covered by t00_futexes.nim.
import std/atomics
import std/posix
import std/unittest
import insideout/futexes

when defined(macosx) or defined(darwin) or defined(bsd):
  suite "futexes (macOS)":
    test "wait() and waitMask() report the expected errno values":
      var x: Atomic[uint32]
      store(x, 1, order = moSequentiallyConsistent)
      # a timed wait that is never woken must time out
      check checkWait(wait(x, 1, timeout = 0.01)) == ETIMEDOUT
      # a wait whose compare value no longer holds must report EAGAIN
      store(x, 2, order = moSequentiallyConsistent)
      check checkWait(wait(x, 1, timeout = 0.01)) == EAGAIN
      # waitMask must also report EAGAIN when the value does not match;
      # x still holds 2, so comparing against 1 is a guaranteed mismatch
      # (comparing against 2 would instead block forever on an un-woken wait)
      let res3 = waitMask(x, 1, 4)
      check checkWait(res3) == EAGAIN
